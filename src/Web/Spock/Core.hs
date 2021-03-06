{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DoAndIfThenElse #-}
module Web.Spock.Core
    ( SpockT, ActionT, spockT
    , middleware, UploadedFile (..)
    , defRoute, get, post, head, put, delete, patch
    , request, header, cookie, body, jsonBody, jsonBody'
    , files, params, param, param', setStatus, setHeader, redirect
    , jumpNext
    , setCookie, setCookie'
    , bytes, lazyBytes, text, html, file, json, blaze
    , combineRoute, subcomponent
    , requireBasicAuth
    )
where

import Control.Arrow (first)
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State hiding (get, put)
import Data.Monoid
import Data.Time
import Network.HTTP.Types.Method
import Network.HTTP.Types.Status
import Prelude hiding (head)
import System.Locale
import Text.Blaze.Html (Html)
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import Web.PathPieces
import Web.Spock.Routing
import Web.Spock.Wire
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as BSL
import qualified Data.CaseInsensitive as CI
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp

-- | Run a raw spock server on a defined port. If you don't need
-- a custom base monad you can just supply 'id' as lift function.
spockT :: MonadIO m
       => Warp.Port
       -> (forall a. m a -> IO a)
       -> SpockT m ()
       -> IO ()
spockT port liftSpock routeDefs =
    do spockApp <- buildApp liftSpock routeDefs
       putStrLn $ "Spock is up and running on port " ++ show port
       Warp.run port spockApp

-- | Specify an action that will be run when the HTTP verb 'GET' and the given route match
get :: MonadIO m => T.Text -> ActionT m () -> SpockT m ()
get = defRoute GET

-- | Specify an action that will be run when the HTTP verb 'POST' and the given route match
post :: MonadIO m => T.Text -> ActionT m () -> SpockT m ()
post = defRoute POST

-- | Specify an action that will be run when the HTTP verb 'HEAD' and the given route match
head :: MonadIO m => T.Text -> ActionT m () -> SpockT m ()
head = defRoute HEAD

-- | Specify an action that will be run when the HTTP verb 'PUT' and the given route match
put :: MonadIO m => T.Text -> ActionT m () -> SpockT m ()
put = defRoute PUT

-- | Specify an action that will be run when the HTTP verb 'DELETE' and the given route match
delete :: MonadIO m => T.Text -> ActionT m () -> SpockT m ()
delete = defRoute DELETE

-- | Specify an action that will be run when the HTTP verb 'PATCH' and the given route match
patch :: MonadIO m => T.Text -> ActionT m () -> SpockT m ()
patch = defRoute PATCH

-- | Get the original Wai Request object
request :: MonadIO m => ActionT m Wai.Request
request = asks ri_request

-- | Read a header
header :: MonadIO m => T.Text -> ActionT m (Maybe T.Text)
header t =
    do req <- request
       return $ fmap T.decodeUtf8 (lookup (CI.mk (T.encodeUtf8 t)) $ Wai.requestHeaders req)

-- | Read a cookie
cookie :: MonadIO m => T.Text -> ActionT m (Maybe T.Text)
cookie name =
    do req <- request
       return $ lookup "cookie" (Wai.requestHeaders req) >>= lookup name . parseCookies . T.decodeUtf8
    where
      parseCookies :: T.Text -> [(T.Text, T.Text)]
      parseCookies = map parseCookie . T.splitOn ";" . T.concat . T.words
      parseCookie = first T.init . T.breakOnEnd "="

-- | Get the raw request body
body :: MonadIO m => ActionT m BS.ByteString
body =
    do req <- request
       let parseBody = liftIO $ Wai.requestBody req
           parseAll chunks =
               do bs <- parseBody
                  if BS.null bs
                  then return chunks
                  else parseAll (chunks `BS.append` bs)
       parseAll BS.empty

-- | Parse the request body as json
jsonBody :: (MonadIO m, A.FromJSON a) => ActionT m (Maybe a)
jsonBody =
    do b <- body
       return $ A.decodeStrict b

-- | Parse the request body as json and fails with 500 status code on error
jsonBody' :: (MonadIO m, A.FromJSON a) => ActionT m a
jsonBody' =
    do b <- body
       case A.eitherDecodeStrict' b of
         Left err ->
             do setStatus status500
                text (T.pack $ "Failed to parse json: " ++ err)
         Right val ->
             return val

-- | Get uploaded files
files :: MonadIO m => ActionT m (HM.HashMap T.Text UploadedFile)
files =
    asks ri_files

-- | Get all request params
params :: MonadIO m => ActionT m [(T.Text, T.Text)]
params =
    do p <- asks ri_params
       qp <- asks ri_queryParams
       return (qp ++ (map (\(k, v) -> (unCaptureVar k, v)) $ HM.toList p))

-- | Read a request param. Spock looks in route captures first, then in POST variables and at last in GET variables
param :: (PathPiece p, MonadIO m) => T.Text -> ActionT m (Maybe p)
param k =
    do p <- asks ri_params
       qp <- asks ri_queryParams
       case HM.lookup (CaptureVar k) p of
         Just val ->
             case fromPathPiece val of
               Nothing ->
                   do liftIO $ putStrLn ("Cannot parse " ++ show k ++ " with value " ++ show val ++ " as path piece!")
                      jumpNext
               Just pathPieceVal ->
                   return $ Just pathPieceVal
         Nothing ->
             return $ join $ fmap fromPathPiece (lookup k qp)

-- | Like 'param', but outputs an error when a param is missing
param' :: (PathPiece p, MonadIO m) => T.Text -> ActionT m p
param' k =
    do mParam <- param k
       case mParam of
         Nothing ->
             do setStatus status500
                text (T.concat [ "Missing parameter ", k ])
         Just val ->
             return val

-- | Set a response status
setStatus :: MonadIO m => Status -> ActionT m ()
setStatus s =
    modify $ \rs -> rs { rs_status = s }

-- | Set a response header. Overwrites already defined headers
setHeader :: MonadIO m => T.Text -> T.Text -> ActionT m ()
setHeader k v =
    modify $ \rs -> rs { rs_responseHeaders = ((k, v) : filter ((/= k) . fst) (rs_responseHeaders rs)) }

-- | Abort the current action and jump the next one matching the route
jumpNext :: MonadIO m => ActionT m a
jumpNext = throwError ActionTryNext

-- | Redirect to a given url
redirect :: MonadIO m => T.Text -> ActionT m a
redirect = throwError . ActionRedirect

-- | Set a cookie living for a given number of seconds
setCookie :: MonadIO m => T.Text -> T.Text -> NominalDiffTime -> ActionT m ()
setCookie name value validSeconds =
    do now <- liftIO getCurrentTime
       setCookie' name value (validSeconds `addUTCTime` now)

-- | Set a cookie living until a specific 'UTCTime'
setCookie' :: MonadIO m => T.Text -> T.Text -> UTCTime -> ActionT m ()
setCookie' name value validUntil =
    setHeader "Set-Cookie" rendered
    where
      rendered =
          let formattedTime =
                  T.pack $ formatTime defaultTimeLocale "%a, %d-%b-%Y %X %Z" validUntil
          in T.concat [ name
                      , "="
                      , value
                      , "; path=/; expires="
                      , formattedTime
                      , ";"
                      ]

-- | Send a 'ByteString' as response body. Provide your own "Content-Type"
bytes :: MonadIO m => BS.ByteString -> ActionT m a
bytes val =
    lazyBytes $ BSL.fromStrict val

-- | Send a lazy 'ByteString' as response body. Provide your own "Content-Type"
lazyBytes :: MonadIO m => BSL.ByteString -> ActionT m a
lazyBytes val =
    do modify $ \rs -> rs { rs_responseBody = ResponseLBS val }
       throwError ActionDone

-- | Send text as a response body. Content-Type will be "text/plain"
text :: MonadIO m => T.Text -> ActionT m a
text val =
    do setHeader "Content-Type" "text/plain"
       bytes $ T.encodeUtf8 val

-- | Send a text as response body. Content-Type will be "text/plain"
html :: MonadIO m => T.Text -> ActionT m a
html val =
    do setHeader "Content-Type" "text/html"
       bytes $ T.encodeUtf8 val

-- | Send a file as response
file :: MonadIO m => T.Text -> FilePath -> ActionT m a
file contentType filePath =
     do setHeader "Content-Type" contentType
        modify $ \rs -> rs { rs_responseBody = ResponseFile filePath }
        throwError ActionDone

-- | Send json as response. Content-Type will be "application/json"
json :: (A.ToJSON a, MonadIO m) => a -> ActionT m b
json val =
    do setHeader "Content-Type" "application/json"
       lazyBytes $ A.encode val

-- | Send blaze html as response. Content-Type will be "text/html"
blaze :: MonadIO m => Html -> ActionT m a
blaze val =
    do setHeader "Content-Type" "text/html"
       lazyBytes $ renderHtml val

-- | Basic authentification
-- provide a title for the prompt and a function to validate
-- user and password. Usage example:
--
-- > get "/my-secret-page" $
-- >   requireBasicAuth "Secret Page" (\user pass -> return (user == "admin" && pass == "1234")) $
-- >   do html "This is top secret content. Login using that secret code I provided ;-)"
--
requireBasicAuth :: MonadIO m => T.Text -> (T.Text -> T.Text -> m Bool) -> ActionT m a -> ActionT m a
requireBasicAuth realmTitle authFun cont =
    do mAuthHeader <- header "Authorization"
       case mAuthHeader of
         Nothing ->
             authFailed
         Just authHeader ->
             let (_, rawValue) =
                     T.breakOn " " authHeader
                 (user, rawPass) =
                     (T.breakOn ":" . T.decodeUtf8 . B64.decodeLenient . T.encodeUtf8 . T.strip) rawValue
                 pass = T.drop 1 rawPass
             in do isOk <- lift $ authFun user pass
                   if isOk
                   then cont
                   else authFailed
    where
      authFailed =
          do setStatus status401
             setHeader "WWW-Authenticate" ("Basic realm=\"" <> realmTitle <> "\"")
             html "<h1>Authentication required.</h1>"
