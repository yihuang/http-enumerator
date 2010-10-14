module Network.TLS.Client.Enumerator
    ( clientEnumSimple
    , clientEnum
    ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Enumerator as E
import qualified Control.Monad.IO.Class as Trans

import Network.TLS.Client
import Network.TLS.SRandom
import Network.TLS.Struct
import Network.TLS.Cipher

import Control.Monad.State (runStateT)

import Data.IORef
import System.IO (Handle)

type IState = IORef TLSStateClient

newIState :: TLSClientParams -> SRandomGen -> IO IState
newIState params rng = do
    ((), tsc) <- runTLSClient (return ()) params rng
    newIORef tsc

clientEnumSimple
    :: Trans.MonadIO m
    => Handle
    -> (E.Iteratee B.ByteString m () -> E.Enumerator B.ByteString m a -> m b)
    -> m b
clientEnumSimple h f = do
    let clientstate = TLSClientParams
            { cpConnectVersion = TLS10
            , cpAllowedVersions = [ TLS10, TLS11 ]
            , cpSession = Nothing
            , cpCiphers = ciphers
            , cpCertificate = Nothing
            , cpCallbacks = TLSClientCallbacks
                { cbCertificates = Nothing
                }
            }
    srand <- Trans.liftIO makeSRandomGen
    clientEnum clientstate srand h f
  where
    ciphers =
        [ cipher_AES128_SHA1
        , cipher_AES256_SHA1
        , cipher_RC4_128_MD5
        , cipher_RC4_128_SHA1
        ]

clientEnum :: Trans.MonadIO m
           => TLSClientParams -> SRandomGen -> Handle
           -> (E.Iteratee B.ByteString m () -> E.Enumerator B.ByteString m a -> m b)
           -> m b
clientEnum tcp srg h f = do
    istate <- Trans.liftIO $ newIState tcp srg
    tlsHelper istate $ connect h
    b <- f (iter istate) (enum istate)
    tlsHelper istate $ close h
    return b
  where
    iter :: Trans.MonadIO m => IState -> E.Iteratee B.ByteString m ()
    iter istate =
        E.continue go
      where
        go E.EOF = return ()
        go (E.Chunks xs) = do
            tlsHelper istate $ sendData h $ L.fromChunks xs
            E.continue go
    enum :: Trans.MonadIO m => IState -> E.Enumerator B.ByteString m a
    enum istate (E.Continue k) = E.Iteratee $ do
        lbs <- tlsHelper istate $ recvData h
        let chunks = E.Chunks $ L.toChunks lbs
        step <- E.runIteratee $ k chunks
        E.runIteratee $ enum istate step
    enum _ step = E.returnI step

tlsHelper :: Trans.MonadIO m => IState -> TLSClient IO a -> m a
tlsHelper istate (TLSClient client) = do
    state <- Trans.liftIO $ readIORef istate
    (ret, state') <- Trans.liftIO $ runStateT client state
    Trans.liftIO $ writeIORef istate state'
    return ret