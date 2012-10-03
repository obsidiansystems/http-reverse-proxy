{-# LANGUAGE OverloadedStrings, NoImplicitPrelude, FlexibleContexts #-}
module Network.HTTP.ReverseProxy
    ( -- * Types
      ProxyDest (..)
      -- * Raw
    , rawProxyTo
      -- * WAI + http-conduit
    , waiProxyTo
    , defaultOnExc
      -- * WAI to Raw
    , waiToRaw
    ) where

import ClassyPrelude.Conduit
import qualified Network.Wai as WAI
import qualified Network.HTTP.Conduit as HC
import Control.Exception.Lifted (try, finally)
import Blaze.ByteString.Builder (fromByteString)
import Data.Word8 (isSpace, _colon, toLower, _cr)
import qualified Data.ByteString.Char8 as S8
import qualified Network.HTTP.Types as HT
import qualified Data.CaseInsensitive as CI
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Conduit.Network as DCN
import Control.Concurrent.MVar.Lifted (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Lifted (fork, killThread)
import Control.Monad.Trans.Control (MonadBaseControl)
import Network.Wai.Handler.Warp (defaultSettings, Connection (..), parseRequest, sendResponse)
import Data.Conduit.Binary (sourceFileRange)
import qualified Data.IORef as I
import Network.Socket (PortNumber (PortNum), SockAddr (SockAddrInet))

-- | Host\/port combination to which we want to proxy.
data ProxyDest = ProxyDest
    { pdHost :: !ByteString
    , pdPort :: !Int
    }

-- | Set up a reverse proxy server, which will have a minimal overhead.
--
-- This function uses raw sockets, parsing as little of the request as
-- possible. The workflow is:
--
-- 1. Parse the first request headers.
--
-- 2. Ask the supplied function to specify how to reverse proxy.
--
-- 3. Open up a connection to the given host\/port.
--
-- 4. Pass all bytes across the wire unchanged.
--
-- If you need more control, such as modifying the request or response, use 'waiProxyTo'.
rawProxyTo :: (MonadBaseControl IO m, MonadIO m)
           => (HT.RequestHeaders -> m (Either (DCN.Application m) ProxyDest))
           -- ^ How to reverse proxy. A @Left@ result will run the given
           -- 'DCN.Application', whereas a @Right@ will reverse proxy to the
           -- given host\/port.
           -> DCN.Application m
rawProxyTo getDest fromClient toClient = do
    (rsrc, headers) <- fromClient $$+ getHeaders
    edest <- getDest headers
    case edest of
        Left app -> do
            -- We know that the socket will be closed by the toClient side, so
            -- we can throw away the finalizer here.
            (fromClient', _) <- unwrapResumable rsrc
            app fromClient' toClient
        Right (ProxyDest host port) -> DCN.runTCPClient (DCN.ClientSettings port $ unpack $ TE.decodeUtf8 host) (withServer rsrc)
  where
    withServer rsrc fromServer toServer = do
        x <- newEmptyMVar
        tid1 <- fork $ (rsrc $$+- toServer) `finally` putMVar x True
        tid2 <- fork $ (fromServer $$ toClient) `finally` putMVar x False
        y <- takeMVar x
        killThread $ if y then tid2 else tid1

-- | Sends a simple 502 bad gateway error message with the contents of the
-- exception.
defaultOnExc :: SomeException -> WAI.Application
defaultOnExc exc _ = return $ WAI.responseLBS
    HT.status502
    [("content-type", "text/plain")]
    ("Error connecting to gateway:\n\n" ++ TLE.encodeUtf8 (show exc))

-- | Creates a WAI 'WAI.Application' which will handle reverse proxies.
--
-- Connections to the proxied server will be provided via http-conduit. As
-- such, all requests and responses will be fully processed in your reverse
-- proxy. This allows you much more control over the data sent over the wire,
-- but also incurs overhead. For a lower-overhead approach, consider
-- 'rawProxyTo'.
--
-- Most likely, the given application should be run with Warp, though in theory
-- other WAI handlers will work as well.
--
-- Note: This function will use chunked request bodies for communicating with
-- the proxied server. Not all servers necessarily support chunked request
-- bodies, so please confirm that yours does (Warp, Snap, and Happstack, for example, do).
waiProxyTo :: (WAI.Request -> ResourceT IO (Either WAI.Response ProxyDest))
           -- ^ How to reverse proxy. A @Left@ result will be sent verbatim as
           -- the response, whereas @Right@ will cause a reverse proxy.
           -> (SomeException -> WAI.Application)
           -- ^ How to handle exceptions when calling remote server. For a
           -- simple 502 error page, use 'defaultOnExc'.
           -> HC.Manager -- ^ connection manager to utilize
           -> WAI.Application
waiProxyTo getDest onError manager req = do
    edest <- getDest req
    case edest of
        Left response -> return response
        Right (ProxyDest host port) -> do
            let req' = HC.def
                    { HC.method = WAI.requestMethod req
                    , HC.host = host
                    , HC.port = port
                    , HC.path = WAI.rawPathInfo req
                    , HC.queryString = WAI.rawQueryString req
                    , HC.requestHeaders = filter (\(key, _) -> not $ key `member` strippedHeaders) $ WAI.requestHeaders req
                    , HC.requestBody = HC.RequestBodySourceChunked $ mapOutput fromByteString $ WAI.requestBody req
                    , HC.redirectCount = 0
                    , HC.checkStatus = \_ _ -> Nothing
                    , HC.responseTimeout = Nothing
                    }
            ex <- try $ HC.http req' manager
            case ex of
                Left e -> onError e req
                Right res -> do
                    (src, _) <- unwrapResumable $ HC.responseBody res
                    return $ WAI.ResponseSource
                        (HC.responseStatus res)
                        (filter (\(key, _) -> not $ key `member` strippedHeaders) $ HC.responseHeaders res)
                        (mapOutput (Chunk . fromByteString) src)
  where
    strippedHeaders = asSet $ fromList ["content-length", "transfer-encoding", "accept-encoding"]
    asSet :: Set a -> Set a
    asSet = id

-- | Get the HTTP headers for the first request on the stream, returning on
-- consumed bytes as leftovers. Has built-in limits on how many bytes it will
-- consume (specifically, will not ask for another chunked after it receives
-- 1000 bytes).
getHeaders :: Monad m => Sink ByteString m HT.RequestHeaders
getHeaders =
    toHeaders <$> go id
  where
    go front =
        await >>= maybe close push
      where
        close = leftover bs >> return bs
          where
            bs = front empty
        push bs'
            | "\r\n\r\n" `S8.isInfixOf` bs
              || "\n\n" `S8.isInfixOf` bs
              || length bs > 1000 = leftover bs >> return bs
            | otherwise = go $ append bs
          where
            bs = front bs'
    toHeaders = map toHeader . takeWhile (not . null) . drop 1 . S8.lines
    toHeader bs =
        (CI.mk key, val)
      where
        (key, bs') = break (== _colon) bs
        val = takeWhile (/= _cr) $ dropWhile isSpace $ drop 1 bs'

-- | Convert a WAI application into a raw application, using Warp.
waiToRaw :: WAI.Application -> DCN.Application IO
waiToRaw app fromClient0 toClient =
    loop $ transPipe lift fromClient0
  where
    loop fromClient = do
        (fromClient', keepAlive) <- runResourceT $ do
            (req, fromClient') <- parseRequest conn 0 dummyAddr fromClient
            res <- app req
            keepAlive <- sendResponse (error "cleaner") req conn res
            (fromClient'', _) <- liftIO fromClient' >>= unwrapResumable
            return (fromClient'', keepAlive)
        if keepAlive
            then loop fromClient'
            else return ()

    dummyAddr = SockAddrInet (PortNum 0) 0 -- FIXME
    conn = Connection
        { connSendMany = \bss -> mapM_ yield bss $$ toClient
        , connSendAll = \bs -> yield bs $$ toClient
        , connSendFile = \fp offset len th headers _cleaner ->
            runResourceT $ sourceFileRange fp (Just offset) (Just len)
                        $$ mapM (\bs -> lift th >> return bs)
                        =$ transPipe lift toClient
        , connClose = return ()
        , connRecv = error "connRecv should not be used"
        }
