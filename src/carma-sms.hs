{-# LANGUAGE OverloadedStrings, FlexibleInstances #-}

module Main (
  main
  ) where

import Prelude hiding (log)

import Control.Concurrent
import Control.Monad.Error
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as C8
import Data.List
import Data.Maybe (mapMaybe)
import qualified Data.Map as M
import Data.String
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Database.Redis as R
import System.Environment
import System.Log
import System.Worker.Redis
import SMSDirect

-- convert arguments to map
-- ["-f1", "value1", "-f2", "value2"] => fromList [("-f1", "value1"), ("-f2", "value2")]
arguments :: [String] -> M.Map String String
arguments = M.fromList . mapMaybe toTuple . splitBy 2 where
  toTuple :: [a] -> Maybe (a, a)
  toTuple [x, y] = Just (x, y)
  toTuple _ = Nothing

  splitBy :: Int -> [a] -> [[a]]
  splitBy = unfoldr . takedrop

  takedrop :: Int -> [a] -> Maybe ([a], [a])
  takedrop n [] = Nothing
  takedrop n xs = Just (take n xs, drop n xs)

-- Argument information
data Argument = Argument {
  argumentFlag :: String,
  argumentName :: String,
  argumentDefault :: String }

-- convert arguments to map with replacing default values
args :: [(String, String)] -> [String] -> M.Map String String
args as s = arguments s `M.union` M.fromList as

instance MonadLog m => MonadLog (ReaderT R.Connection m) where
  askLog = lift askLog

rules :: String -> Rules
rules r = [
  parseRule_ (fromString $ "/: use " ++ r)]

-- Logs error and return
smsdirect' :: MonadLog m => T.Text -> T.Text -> SMSDirect.Command a -> m (Either String a)
smsdirect' u p cmd = scope "direct" $ do
  log Trace $ T.concat ["URL: ", fromString $ url u p cmd]
  v <- liftIO $ smsdirect u p cmd
  case v of
    Left code -> do
      log Error $ T.concat ["Error code: ", fromString $ show code]
      return $ Left $ show code
    Right x -> return $ Right x

ignore :: Monad m => m a -> m ()
ignore = (>> return ())

main :: IO ()
main = do
  as <- getArgs
  if null as
    then printUsage
    else main' (args argDecl as)
  where
    argDecl = [
      ("-u", error "User not specified"),
      ("-p", error "Password not specified"),
      ("-l", "default"),
      ("-k", "smspost"),
      ("-i", "1")]
    printUsage = mapM_ putStrLn $ [
      "Usage: carma-sms [flags] where",
      "  -u <user> - login for smsdirect",
      "  -p <pass> - password for smsdirect",
      "  -l <level> - log level, default is 'default', possible values are: trace, debug, default, silent",
      "  -k <key> - redis key for tasks, default is 'smspost'",
      "  -i <id> - id of task-processing list, default is '1' (key will be 'smspost:1')",
      "",
      "Examples:",
      "  carma-sms -u user -p pass",
      "  carma-sms -u user -p pass -l trace",
      "  carma-sms -u user -p pass -l silent -k smspostlist"]
    main' flags = do
      conn <- R.connect R.defaultConnectInfo
      l <- newLog (constant (rules $ flag "-l")) [logger text (file "carma-sms.log")]
      withLog l $ do
        scope "sms" $ log Info $ T.concat ["Starting sms for user ", user, " with password ", pass]
        runTask conn $ processTasks (fromString $ flag "-k") (fromString $ flag "-k" ++ ":" ++ flag "-i") process onError
      where
        process i m = scope "sms" $ scope (T.decodeUtf8 i) $ do
          log Trace $ T.concat ["Sender: ", from]
          log Trace $ T.concat ["To: ", to]
          log Trace $ T.concat ["Message: ", msg]
          log Trace $ T.concat ["Action: ", action]

          maybe noAction id $ M.lookup action actions

          liftIO $ threadDelay 200000 -- 5 messages per second
          where
            actions = M.fromList [
              ("send", sendAction),
              ("status", statusAction)]

            sendAction :: (MonadLog m) => TaskMonad m ()
            sendAction = ignore $ runErrorT $ do
              mid <- ErrorT $ smsdirect' user pass $ submitMessage from (phone to) msg Nothing
              lift $ do
                log Trace $ T.concat ["Message id: ", fromString $ show mid]
                redisInTask $ do
                  R.hmset i [
                    ("msgid", C8.pack $ show mid),
                    ("msgstatus", "1"),
                    ("action", "status")]
                  R.lpush (fromString $ flag "-k") [i]

            statusAction :: (MonadLog m) => TaskMonad m ()
            statusAction = ignore $ runErrorT $ do
              st <- ErrorT $ smsdirect' user pass $ statusMessage (read . T.unpack $ msgid)
              lift $ do
                log Trace $ T.concat ["Status of message ", msgid, ": ", fromString $ show st]
                if st == 1
                  then redisInTask $ do
                    R.hmset i [("msgstatus", "1")]
                    R.lpush (fromString $ flag "-k") [i]
                    return ()
                  else redisInTask $ do
                    R.hmset i [
                      ("msgstatus", fromString $ show st),
                      ("action", "")]
                    return ()

            noAction = log Error $ T.concat ["Invalid action: ", action]

            from = T.decodeUtf8 $ m M.! "from"
            to = T.decodeUtf8 $ m M.! "phone"
            msg = T.decodeUtf8 $ m M.! "msg"
            msgid = T.decodeUtf8 $ m M.! "msgid"
            action = maybe "send" T.decodeUtf8 $ M.lookup "action" m

        onError i = scope "sms" $ log Error $ T.concat ["Unable to process: ", T.decodeUtf8 i]
        flag = (flags M.!)
        user :: T.Text
        user = fromString $ flag "-u"
        pass :: T.Text
        pass = fromString $ flag "-p"
