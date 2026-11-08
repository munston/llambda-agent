{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), eitherDecode, encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (fromText)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import Data.Char (isSpace)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Network.HTTP.Client (Manager, RequestBody (..), httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (Status, hContentType, status200, status400, status404, status500, statusCode)
import Network.Wai (Application, Response, rawPathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (run)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Environment (getArgs, getProgName)
import System.Exit (die, exitFailure)
import System.FilePath (normalise, pathSeparator, takeDirectory, (</>))
import System.IO (hFlush, hSetEncoding, stdout, stderr, utf8)
import Text.Read (readMaybe)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)

data Config = Config
  { cfgBaseUrl :: Text
  , cfgModel :: Text
  , cfgApiKey :: Text
  }

data ToolCall = ToolCall
  { tcId :: Text
  , tcName :: Text
  , tcArgs :: Text
  }

data Turn = Turn
  { turnContent :: Maybe Text
  , turnCalls :: [ToolCall]
  }

maxTurns :: Int
maxTurns = 12

historyLimit :: Int
historyLimit = 5

data Options = Options
  { optConfig :: Maybe FilePath
  , optNoHistory :: Bool
  , optServe :: Maybe Int
  }

data Exchange = Exchange
  { exchangeUser :: Text
  , exchangeAssistant :: Text
  }

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- getArgs
  case args of
    [] -> usage >> exitFailure
    ["--help"] -> usage
    _ -> do
      let (options, taskParts) = splitArgs args
      root <- canonicalizePath "."
      cfg <- loadConfig (optConfig options)
      case optServe options of
        Just port -> serveAgent port cfg root
        Nothing ->
          if null taskParts
            then usage >> exitFailure
            else do
              let task = T.unwords (map T.pack taskParts)
              header <- loadHeader
              prior <- if optNoHistory options then pure [] else loadHistory root
              TIO.putStrLn $ "model: " <> cfgModel cfg
              TIO.putStrLn $
                if optNoHistory options
                  then "history: off"
                  else "history: " <> T.pack (show (length prior)) <> " of " <> T.pack (show historyLimit)
              manager <- newManager tlsManagerSettings
              answer <- loop manager cfg root 1 (systemMsg header prior : historyMessages prior ++ [userMsg task])
              if optNoHistory options
                then pure ()
                else saveHistory root (takeLast historyLimit (prior ++ [Exchange task answer]))

usage :: IO ()
usage = do
  name <- getProgName
  putStrLn $ "usage: " ++ name ++ " [--config FILE] [--no-history] <task>\n       " ++ name ++ " [--config FILE] --serve PORT"

splitArgs :: [String] -> (Options, [String])
splitArgs = go (Options Nothing False Nothing)
  where
    go opts ("--config" : path : rest) = go opts {optConfig = Just path} rest
    go opts ("--no-history" : rest) = go opts {optNoHistory = True} rest
    go opts ("--serve" : portText : rest) =
      case readMaybe portText of
        Just port -> go opts {optServe = Just port} rest
        Nothing -> (opts, "--serve" : portText : rest)
    go opts rest = (opts, rest)

data Inbound = Inbound {inMessages :: [Value]}

instance FromJSON Inbound where
  parseJSON = withObject "chat request" $ \o -> Inbound <$> o .: "messages"

serveAgent :: Int -> Config -> FilePath -> IO ()
serveAgent port cfg root = do
  manager <- newManager tlsManagerSettings
  TIO.putStrLn $ "listening on http://127.0.0.1:" <> T.pack (show port) <> "/v1/chat/completions"
  TIO.putStrLn $ "model: " <> cfgModel cfg
  hFlush stdout
  header <- loadHeader
  TIO.putStrLn $ "header: " <> T.take 80 (T.replace "\n" " " header)
  run port (application manager cfg root header)

application :: Manager -> Config -> FilePath -> Text -> Application
application manager cfg root header req respond
  | requestMethod req == "POST" && rawPathInfo req == "/v1/chat/completions" = do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> respond (json status400 (errBody ("bad request: " <> T.pack err)))
        Right inbound -> do
          outcome <- try (loop manager cfg root 1 (withSystem (inMessages inbound))) :: IO (Either SomeException Text)
          case outcome of
            Left err -> respond (json status500 (errBody ("agent error: " <> T.pack (show err))))
            Right answer -> respond (json status200 (completion cfg answer))
  | otherwise = respond (json status404 (errBody "not found"))
  where
    withSystem messages =
      case messages of
        Object first : _
          | KM.lookup (fromText "role") first == Just (String "system") -> messages
        _ -> systemMsg header [] : messages

json :: ToJSON a => Status -> a -> Response
json status payload = responseLBS status [(hContentType, "application/json")] (encode payload)

errBody :: Text -> Value
errBody message =
  object
    [ "error"
        .= object
          [ "message" .= message
          , "type" .= ("invalid_request_error" :: Text)
          ]
    ]

completion :: Config -> Text -> Value
completion cfg answer =
  object
    [ "id" .= ("chatcmpl-lllambda-agent" :: Text)
    , "object" .= ("chat.completion" :: Text)
    , "created" .= (1710000000 :: Int)
    , "model" .= cfgModel cfg
    , "choices"
        .= [ object
              [ "index" .= (0 :: Int)
              , "message" .= object ["role" .= ("assistant" :: Text), "content" .= answer]
              , "finish_reason" .= ("stop" :: Text)
              ]
           ]
    ]

historyPath :: FilePath -> FilePath
historyPath root = root </> "agent-history.json"

loadHistory :: FilePath -> IO [Exchange]
loadHistory root = do
  exists <- doesFileExist (historyPath root)
  if not exists
    then pure []
    else do
      raw <- BL.readFile (historyPath root)
      case eitherDecode raw of
        Right items -> pure (takeLast historyLimit items)
        Left _ -> pure []

saveHistory :: FilePath -> [Exchange] -> IO ()
saveHistory root items = BL.writeFile (historyPath root) (encode items)

historyMessages :: [Exchange] -> [Value]
historyMessages = concatMap (\item -> [userMsg (exchangeUser item), assistantText (exchangeAssistant item)])

assistantText :: Text -> Value
assistantText text = object ["role" .= ("assistant" :: Text), "content" .= text]

takeLast :: Int -> [a] -> [a]
takeLast n xs = drop (length xs - n) xs

loadConfig :: Maybe FilePath -> IO Config
loadConfig explicit = do
  path <- maybe (findConfig ["llambda-agent.config"]) pure explicit
  raw <- T.pack <$> readFile path
  let pairs =
        [ (T.strip key, T.strip (T.drop 1 rest))
        | line <- T.lines raw
        , let trimmed = T.strip line
        , not (T.null trimmed)
        , not ("#" `T.isPrefixOf` trimmed)
        , let (key, rest) = T.breakOn "=" trimmed
        , not (T.null rest)
        ]
      need key = case lookup key pairs of
        Just value | not (T.null value) -> pure value
        _ -> die $ "missing " ++ T.unpack key ++ " in " ++ path
  Config <$> need "base-url" <*> need "model" <*> need "api-key"

findConfig :: [FilePath] -> IO FilePath
findConfig [] = die "llambda-agent.config not found. Pass --config FILE."
findConfig (path : rest) = do
  exists <- doesFileExist path
  if exists then canonicalizePath path else findConfig rest

loop :: Manager -> Config -> FilePath -> Int -> [Value] -> IO Text
loop manager cfg root n messages
  | n > maxTurns = die "agent stopped: turn limit reached"
  | otherwise = do
      putStrLn $ "turn " ++ show n
      hFlush stdout
      turn <- chat cfg manager messages
      case turnCalls turn of
        [] -> do
          let answer = fromMaybe "" (turnContent turn)
          TIO.putStrLn answer
          pure answer
        calls -> do
          results <- mapM (runTool root) calls
          loop manager cfg root (n + 1) (messages ++ assistantMsg turn : results)

loadHeader :: IO Text
loadHeader = do
  let path = "bench" </> "remembered-header.txt"
  exists <- doesFileExist path
  if not exists
    then pure basePrompt
    else do
      text <- T.strip <$> TIO.readFile path
      if T.null text then pure basePrompt else pure text

systemMsg :: Text -> [Exchange] -> Value
systemMsg prompt prior =
  object
    [ "role" .= ("system" :: Text)
    , "content" .= (prompt <> memoryBlock prior)
    ]

basePrompt :: Text
basePrompt =
  "You are a coding agent working in the current directory. The earlier messages are this conversation's memory. Use them when the user follows up, and do not claim you have forgotten them. Use tools only when the task needs the workspace. Keep edits limited to the task. Do not read llambda-agent.config. When the task is finished, answer in plain text and do not call a tool."

memoryBlock :: [Exchange] -> Text
memoryBlock [] = ""
memoryBlock prior =
  "\n\nMemory of the recent conversation:\n"
    <> T.intercalate "\n" (map one prior)
  where
    one item = "User: " <> exchangeUser item <> "\nAssistant: " <> exchangeAssistant item

userMsg :: Text -> Value
userMsg task = object ["role" .= ("user" :: Text), "content" .= task]

assistantMsg :: Turn -> Value
assistantMsg turn =
  object
    [ "role" .= ("assistant" :: Text)
    , "content" .= turnContent turn
    , "tool_calls" .= map encodeCall (turnCalls turn)
    ]

encodeCall :: ToolCall -> Value
encodeCall tc =
  object
    [ "id" .= tcId tc
    , "type" .= ("function" :: Text)
    , "function" .= object ["name" .= tcName tc, "arguments" .= tcArgs tc]
    ]

toolSpecs :: [Value]
toolSpecs =
  [ fn "list_dir" "List entries in a directory relative to the workspace." ["path"]
  , fn "read_file" "Read a text file relative to the workspace." ["path"]
  , fn "write_file" "Write a text file relative to the workspace." ["path", "contents"]
  , fn "run" "Run a PowerShell command in the workspace." ["command"]
  ]
  where
    fn name desc required =
      object
        [ "type" .= ("function" :: Text)
        , "function"
            .= object
              [ "name" .= (name :: Text)
              , "description" .= (desc :: Text)
              , "parameters"
                  .= object
                    [ "type" .= ("object" :: Text)
                    , "properties" .= object [prop n | n <- required]
                    , "required" .= required
                    ]
              ]
        ]
    prop name = fromText name .= object ["type" .= ("string" :: Text)]

chat :: Config -> Manager -> [Value] -> IO Turn
chat cfg manager messages = do
  let url = T.unpack (T.dropWhileEnd isSpace (cfgBaseUrl cfg) <> "/chat/completions")
  initReq <- parseRequest url
  let body =
        encode $
          object
            [ "model" .= cfgModel cfg
            , "messages" .= messages
            , "tools" .= toolSpecs
            , "tool_choice" .= ("auto" :: Text)
            , "max_tokens" .= (2048 :: Int)
            , "temperature" .= (0 :: Int)
            ]
      req =
        initReq
          { method = "POST"
          , requestBody = RequestBodyLBS body
          , requestHeaders =
              [ ("Authorization", "Bearer " <> TE.encodeUtf8 (cfgApiKey cfg))
              , ("Content-Type", "application/json")
              , ("Accept", "application/json")
              ]
          }
  resp <- httpLbs req manager
  let code = statusCode (responseStatus resp)
      raw = responseBody resp
  if code /= 200
    then die $ "model request failed: HTTP " ++ show code ++ " " ++ take 400 (B8.unpack (BL.toStrict raw))
    else case eitherDecode raw of
      Left err -> die $ "bad model response: " ++ err
      Right turn -> pure turn

runTool :: FilePath -> ToolCall -> IO Value
runTool root tc = do
  outcome <- try (dispatch root tc) :: IO (Either SomeException Text)
  let text = case outcome of
        Left err -> "error: " <> T.pack (show err)
        Right ok -> ok
  TIO.putStrLn $ "tool_call " <> TE.decodeUtf8 (BL.toStrict (encode (object ["name" .= tcName tc, "arguments" .= tcArgs tc])))
  TIO.putStrLn $ "tool " <> tcName tc <> " -> " <> T.take 200 (T.replace "\n" " " text)
  pure $ object ["role" .= ("tool" :: Text), "tool_call_id" .= tcId tc, "content" .= text]

dispatch :: FilePath -> ToolCall -> IO Text
dispatch root tc = do
  args <- case eitherDecode (BL.fromStrict (TE.encodeUtf8 (tcArgs tc))) of
    Right v -> pure (v :: Value)
    Left err -> die $ "tool arguments were not JSON: " ++ err
  case tcName tc of
    "list_dir" -> do
      path <- inside root (field args "path")
      names <- listDirectory path
      pure $ T.pack (unlines names)
    "read_file" -> do
      path <- inside root (field args "path")
      refuseSecret path
      T.pack <$> readFile path
    "write_file" -> do
      path <- inside root (field args "path")
      refuseSecret path
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path (T.unpack (field args "contents"))
      pure "wrote file"
    "run" -> do
      let command = T.unpack (field args "command")
          process = (proc "pwsh" ["-NoProfile", "-Command", command]) {cwd = Just root}
      (code, out, err) <- readCreateProcessWithExitCode process ""
      pure $ T.pack $ take 12000 $ unlines ["exit: " ++ show code, out, err]
    other -> pure $ "unknown tool: " <> other

field :: Value -> Text -> Text
field (Object o) key = case KM.lookup (fromText key) o of
  Just (String s) -> s
  Just other -> T.pack (show other)
  Nothing -> ""
field _ _ = ""

inside :: FilePath -> Text -> IO FilePath
inside root relText = do
  let rel = T.unpack relText
      parts = words (map (\c -> if c == '/' || c == '\\' then ' ' else c) rel)
  if ".." `elem` parts
    then die $ "path escapes the workspace: " ++ rel
    else do
      target <- canonicalizePath (if null rel then root else root </> rel)
      rootCanon <- canonicalizePath root
      let prefix = rootCanon ++ [pathSeparator]
      if rootCanon == target || prefix `isPrefixOf` target
        then pure target
        else die $ "path escapes the workspace: " ++ rel

refuseSecret :: FilePath -> IO ()
refuseSecret path
  | "llambda-agent.config" `isSuffixOf` normalise path = die "refusing to touch llambda-agent.config"
  | otherwise = pure ()

instance ToJSON Exchange where
  toJSON item =
    object
      [ "user" .= exchangeUser item
      , "assistant" .= exchangeAssistant item
      ]

instance FromJSON Exchange where
  parseJSON = withObject "exchange" $ \o ->
    Exchange <$> o .: "user" <*> o .: "assistant"

instance FromJSON ToolCall where
  parseJSON = withObject "tool_call" $ \o -> do
    callId <- o .: "id"
    fn <- o .: "function"
    name <- fn .: "name"
    arguments <- fn .: "arguments"
    pure ToolCall {tcId = callId, tcName = name, tcArgs = arguments}

instance FromJSON Turn where
  parseJSON = withObject "response" $ \o -> do
    choices <- o .: "choices"
    case choices of
      [] -> fail "no choices"
      Object choice : _ -> do
        message <- choice .: "message"
        withObject "message" parseMessage message
      _ -> fail "choice was not an object"
    where
      parseMessage message = do
        content <- message .:? "content"
        calls <- message .:? "tool_calls"
        pure Turn {turnContent = textContent content, turnCalls = fromMaybe [] calls}

textContent :: Maybe Value -> Maybe Text
textContent (Just (String s))
  | not (T.null (T.strip s)) = Just s
textContent _ = Nothing
