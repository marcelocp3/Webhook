{-# LANGUAGE ForeignFunctionInterface #-}

module Main (main) where

import Control.Exception (SomeException, bracket, catch, finally)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isDigit, isSpace, toLower, toUpper)
import Data.List (dropWhileEnd, findIndex, isPrefixOf)
import qualified Data.Set as Set
import Data.Set (Set)
import Foreign
import Foreign.C

secretToken :: String
secretToken = "meu-token-secreto"

gatewayHost :: String
gatewayHost = "127.0.0.1"

gatewayPort :: CUShort
gatewayPort = 5001

webhookPort :: CUShort
webhookPort = 5000

expectedAmount :: String
expectedAmount = "49.90"

expectedCurrency :: String
expectedCurrency = "BRL"

transactionDbPath :: FilePath
transactionDbPath = "transactions.db"

afInet, sockStream, solSocket, soReuseAddr :: CInt
afInet = 2
sockStream = 1
solSocket = 1
soReuseAddr = 2

foreign import ccall unsafe "socket"
  c_socket :: CInt -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "setsockopt"
  c_setsockopt :: CInt -> CInt -> CInt -> Ptr CInt -> CUInt -> IO CInt

foreign import ccall unsafe "bind"
  c_bind :: CInt -> Ptr () -> CUInt -> IO CInt

foreign import ccall unsafe "listen"
  c_listen :: CInt -> CInt -> IO CInt

foreign import ccall safe "accept"
  c_accept :: CInt -> Ptr () -> Ptr CUInt -> IO CInt

foreign import ccall safe "connect"
  c_connect :: CInt -> Ptr () -> CUInt -> IO CInt

foreign import ccall unsafe "close"
  c_close :: CInt -> IO CInt

foreign import ccall safe "recv"
  c_recv :: CInt -> Ptr CChar -> CSize -> CInt -> IO CLong

foreign import ccall safe "send"
  c_send :: CInt -> Ptr CChar -> CSize -> CInt -> IO CLong

foreign import ccall unsafe "htons"
  c_htons :: CUShort -> CUShort

foreign import ccall unsafe "inet_addr"
  c_inet_addr :: CString -> IO CUInt

data Request = Request
  { requestMethod :: String
  , requestPath :: String
  , requestHeaders :: [(String, String)]
  , requestBody :: String
  }

data Response = Response
  { responseStatus :: Int
  , responseBody :: String
  }

data GatewayAction = GatewayAction String String

data TransactionRecord = TransactionRecord
  { recordStatus :: String
  , recordTxId :: String
  , recordReason :: String
  }

main :: IO ()
main = do
  serverFd <- openServerSocket webhookPort
  putStrLn "Webhook Haskell ouvindo em http://127.0.0.1:5000/webhook"
  loop serverFd Set.empty
 where
  loop serverFd confirmed = do
    clientFd <- c_accept serverFd nullPtr nullPtr
    if clientFd < 0
      then loop serverFd confirmed
      else do
        nextConfirmed <- handleClient confirmed clientFd `finally` ignoreClose clientFd
        loop serverFd nextConfirmed

handleClient :: Set String -> CInt -> IO (Set String)
handleClient confirmed clientFd =
  ( do
      raw <- readHttpRequest clientFd
      let request = parseRequest raw
          (response, nextConfirmed, action, record) = processRequest confirmed request
      persistTransaction record
      runGatewayAction action
      sendResponse clientFd response
      pure nextConfirmed
  )
    `catch` \(err :: SomeException) -> do
      let body = jsonStatus "error" [("reason", "internal error")]
      sendResponse clientFd (Response 500 body) `catch` \(_ :: SomeException) -> pure ()
      putStrLn ("Erro ao processar requisicao: " ++ show err)
      pure confirmed

openServerSocket :: CUShort -> IO CInt
openServerSocket port = do
  fd <- c_socket afInet sockStream 0
  when (fd < 0) (fail "nao foi possivel criar socket")
  setReuseAddr fd
  bindAny fd port
  result <- c_listen fd 128
  when (result < 0) (fail "nao foi possivel escutar na porta 5000")
  pure fd

setReuseAddr :: CInt -> IO ()
setReuseAddr fd =
  alloca $ \opt -> do
    poke opt (1 :: CInt)
    result <- c_setsockopt fd solSocket soReuseAddr opt (fromIntegral (sizeOf (1 :: CInt)))
    when (result < 0) (fail "setsockopt SO_REUSEADDR falhou")

bindAny :: CInt -> CUShort -> IO ()
bindAny fd port =
  withSockAddr Nothing port $ \addr -> do
    result <- c_bind fd addr 16
    when (result < 0) (fail "bind falhou: porta 5000 indisponivel")

withSockAddr :: Maybe String -> CUShort -> (Ptr () -> IO a) -> IO a
withSockAddr maybeHost port action =
  allocaBytes 16 $ \raw -> do
    fillBytes raw 0 16
    pokeByteOff raw 0 (fromIntegral afInet :: CUShort)
    pokeByteOff raw 2 (c_htons port :: CUShort)
    addr <-
      case maybeHost of
        Nothing -> pure 0
        Just host -> withCString host c_inet_addr
    pokeByteOff raw 4 (addr :: CUInt)
    action (castPtr raw)

readHttpRequest :: CInt -> IO String
readHttpRequest fd = go ""
 where
  go acc = do
    chunk <- recvChunk fd
    let next = acc ++ chunk
    if null chunk || requestComplete next
      then pure next
      else go next

recvChunk :: CInt -> IO String
recvChunk fd =
  allocaBytes 4096 $ \buffer -> do
    received <- c_recv fd buffer 4096 0
    if received <= 0
      then pure ""
      else BSC.unpack <$> BS.packCStringLen (buffer, fromIntegral received)

requestComplete :: String -> Bool
requestComplete raw =
  case splitHeaderBody raw of
    Nothing -> False
    Just (headers, body) ->
      case lookupHeader "content-length" (parseHeaders headers) of
        Nothing -> True
        Just lenText ->
          case reads lenText of
            [(len, "")] -> length body >= len
            _ -> True

parseRequest :: String -> Request
parseRequest raw =
  case splitHeaderBody raw of
    Nothing -> Request "" "" [] ""
    Just (headerText, bodyText) ->
      let headerLines = lines headerText
          firstLine = case headerLines of
            [] -> []
            line : _ -> words line
          (method, path) = case firstLine of
            methodText : pathText : _ -> (methodText, pathText)
            methodText : _ -> (methodText, "")
            [] -> ("", "")
       in Request method path (parseHeaders headerText) bodyText

parseHeaders :: String -> [(String, String)]
parseHeaders headerText =
  mapMaybeHeader (drop 1 (lines headerText))
 where
  mapMaybeHeader [] = []
  mapMaybeHeader (line : rest) =
    case break (== ':') line of
      (_, "") -> mapMaybeHeader rest
      (name, value) -> (map toLower (trim name), trim (drop 1 value)) : mapMaybeHeader rest

lookupHeader :: String -> [(String, String)] -> Maybe String
lookupHeader name headers = lookup (map toLower name) headers

processRequest :: Set String -> Request -> (Response, Set String, Maybe GatewayAction, Maybe TransactionRecord)
processRequest confirmed request
  | requestMethod request /= "POST" =
      (Response 405 (jsonStatus "error" [("reason", "method not allowed")]), confirmed, Nothing, Nothing)
  | requestPath request /= "/webhook" =
      (Response 404 (jsonStatus "error" [("reason", "not found")]), confirmed, Nothing, Nothing)
  | lookupHeader "x-webhook-token" (requestHeaders request) /= Just secretToken =
      (Response 403 (jsonStatus "ignored" [("reason", "invalid token")]), confirmed, Nothing, Nothing)
  | otherwise =
      processPayload confirmed (requestBody request)

processPayload :: Set String -> String -> (Response, Set String, Maybe GatewayAction, Maybe TransactionRecord)
processPayload confirmed body =
  case field "transaction_id" of
    Nothing ->
      (Response 400 (jsonStatus "cancelled" [("reason", "missing field: transaction_id")]), confirmed, Nothing, Nothing)
    Just txId
      | missingRequired /= [] ->
          cancelled txId "missing required field"
      | Just reason <- validatePayloadIntegrity body ->
          cancelled txId reason
      | Set.member txId confirmed ->
          cancelled txId "transaction duplicated"
      | field "amount" /= Just expectedAmount || field "currency" /= Just expectedCurrency ->
          cancelled txId "mismatch"
      | otherwise ->
          ( Response 200 (jsonStatus "confirmed" [("transaction_id", txId)])
          , Set.insert txId confirmed
          , Just (GatewayAction "confirmar" txId)
          , Just (TransactionRecord "confirmed" txId "ok")
          )
 where
  field key = extractJsonField key body
  missingRequired = filter (\key -> field key == Nothing) ["event", "amount", "currency", "timestamp"]
  cancelled txId reason =
    ( Response 400 (jsonStatus "cancelled" [("transaction_id", txId), ("reason", reason)])
    , confirmed
    , Just (GatewayAction "cancelar" txId)
    , Just (TransactionRecord "cancelled" txId reason)
    )

validatePayloadIntegrity :: String -> Maybe String
validatePayloadIntegrity body
  | not (isNonEmpty "transaction_id") = Just "empty transaction_id"
  | field "event" /= Just "payment_success" = Just "invalid event"
  | maybe True (not . isValidMoney) (field "amount") = Just "invalid amount format"
  | maybe True (not . isValidCurrency) (field "currency") = Just "invalid currency format"
  | maybe True (not . isValidTimestamp) (field "timestamp") = Just "invalid timestamp format"
  | otherwise = Nothing
 where
  field key = extractJsonField key body
  isNonEmpty key = maybe False (not . null . trim) (field key)

isValidMoney :: String -> Bool
isValidMoney amount =
  case break (== '.') amount of
    (reais, '.' : cents) -> not (null reais) && all isDigit reais && length cents == 2 && all isDigit cents
    _ -> False

isValidCurrency :: String -> Bool
isValidCurrency currency =
  length currency == 3 && all (\ch -> toUpper ch == ch && ch >= 'A' && ch <= 'Z') currency

isValidTimestamp :: String -> Bool
isValidTimestamp timestamp =
  length timestamp == 20
    && digitsAt [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
    && charAt 4 == '-'
    && charAt 7 == '-'
    && charAt 10 == 'T'
    && charAt 13 == ':'
    && charAt 16 == ':'
    && charAt 19 == 'Z'
 where
  charAt index = timestamp !! index
  digitsAt = all (isDigit . charAt)

persistTransaction :: Maybe TransactionRecord -> IO ()
persistTransaction Nothing = pure ()
persistTransaction (Just record) =
  appendFile transactionDbPath (renderTransactionRecord record ++ "\n")
    `catch` \(_ :: SomeException) -> pure ()

renderTransactionRecord :: TransactionRecord -> String
renderTransactionRecord record =
  "{"
    ++ joinComma
      [ "\"status\":\"" ++ jsonEscape (recordStatus record) ++ "\""
      , "\"transaction_id\":\"" ++ jsonEscape (recordTxId record) ++ "\""
      , "\"reason\":\"" ++ jsonEscape (recordReason record) ++ "\""
      ]
    ++ "}"

runGatewayAction :: Maybe GatewayAction -> IO ()
runGatewayAction Nothing = pure ()
runGatewayAction (Just (GatewayAction endpoint txId)) =
  notifyGateway endpoint txId `catch` \(_ :: SomeException) -> pure ()

notifyGateway :: String -> String -> IO ()
notifyGateway endpoint txId =
  bracket open closeSocket $ \fd -> do
    withSockAddr (Just gatewayHost) gatewayPort $ \addr -> do
      result <- c_connect fd addr 16
      when (result < 0) (fail "gateway indisponivel")
    sendAll fd request
    _ <- recvChunk fd
    pure ()
 where
  open = do
    fd <- c_socket afInet sockStream 0
    when (fd < 0) (fail "nao foi possivel criar socket do gateway")
    pure fd
  body = "{\"transaction_id\":\"" ++ jsonEscape txId ++ "\"}"
  request =
    BSC.pack $
      "POST /"
        ++ endpoint
        ++ " HTTP/1.1\r\n"
        ++ "Host: "
        ++ gatewayHost
        ++ ":5001\r\n"
        ++ "Content-Type: application/json\r\n"
        ++ "Content-Length: "
        ++ show (length body)
        ++ "\r\nConnection: close\r\n\r\n"
        ++ body

sendResponse :: CInt -> Response -> IO ()
sendResponse fd response =
  sendAll fd $
    BSC.pack $
      "HTTP/1.1 "
        ++ show status
        ++ " "
        ++ statusText status
        ++ "\r\nContent-Type: application/json\r\nContent-Length: "
        ++ show (length body)
        ++ "\r\nConnection: close\r\n\r\n"
        ++ body
 where
  status = responseStatus response
  body = responseBody response

sendAll :: CInt -> ByteString -> IO ()
sendAll fd bytes
  | BS.null bytes = pure ()
  | otherwise =
      BS.useAsCStringLen bytes $ \(ptr, len) -> do
        sent <- c_send fd ptr (fromIntegral len) 0
        when (sent <= 0) (fail "send falhou")
        sendAll fd (BS.drop (fromIntegral sent) bytes)

closeSocket :: CInt -> IO ()
closeSocket fd = do
  _ <- c_close fd
  pure ()

ignoreClose :: CInt -> IO ()
ignoreClose fd = closeSocket fd `catch` \(_ :: SomeException) -> pure ()

statusText :: Int -> String
statusText 200 = "OK"
statusText 400 = "Bad Request"
statusText 403 = "Forbidden"
statusText 404 = "Not Found"
statusText 405 = "Method Not Allowed"
statusText 500 = "Internal Server Error"
statusText _ = "Unknown"

splitHeaderBody :: String -> Maybe (String, String)
splitHeaderBody raw =
  case findIndex ("\r\n\r\n" `isPrefixOf`) (suffixes raw) of
    Just index -> Just (take index raw, drop (index + 4) raw)
    Nothing ->
      case findIndex ("\n\n" `isPrefixOf`) (suffixes raw) of
        Just index -> Just (take index raw, drop (index + 2) raw)
        Nothing -> Nothing

suffixes :: [a] -> [[a]]
suffixes [] = [[]]
suffixes xs@(_ : rest) = xs : suffixes rest

extractJsonField :: String -> String -> Maybe String
extractJsonField key body = do
  afterKey <- findAfter ("\"" ++ key ++ "\"") body
  afterColon <- consumeColon afterKey
  parseJsonValue afterColon

findAfter :: String -> String -> Maybe String
findAfter needle haystack =
  case findIndex (needle `isPrefixOf`) (suffixes haystack) of
    Nothing -> Nothing
    Just index -> Just (drop (index + length needle) haystack)

consumeColon :: String -> Maybe String
consumeColon text =
  case dropWhile isSpace text of
    ':' : rest -> Just (dropWhile isSpace rest)
    _ -> Nothing

parseJsonValue :: String -> Maybe String
parseJsonValue ('"' : rest) = Just (readJsonString rest)
parseJsonValue text =
  let value = takeWhile (\ch -> ch /= ',' && ch /= '}' && not (isSpace ch)) text
   in if null value then Nothing else Just value

readJsonString :: String -> String
readJsonString [] = []
readJsonString ('\\' : '"' : rest) = '"' : readJsonString rest
readJsonString ('\\' : '\\' : rest) = '\\' : readJsonString rest
readJsonString ('"' : _) = []
readJsonString (ch : rest) = ch : readJsonString rest

jsonStatus :: String -> [(String, String)] -> String
jsonStatus status fields =
  "{"
    ++ joinComma (("\"status\":\"" ++ jsonEscape status ++ "\"") : map renderField fields)
    ++ "}"
 where
  renderField (key, value) = "\"" ++ jsonEscape key ++ "\":\"" ++ jsonEscape value ++ "\""

jsonEscape :: String -> String
jsonEscape [] = []
jsonEscape ('"' : rest) = '\\' : '"' : jsonEscape rest
jsonEscape ('\\' : rest) = '\\' : '\\' : jsonEscape rest
jsonEscape (ch : rest) = ch : jsonEscape rest

joinComma :: [String] -> String
joinComma [] = ""
joinComma [item] = item
joinComma (item : rest) = item ++ "," ++ joinComma rest

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
