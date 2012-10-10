{-# LANGUAGE OverloadedStrings #-}

-- | SMS posting for carma
-- 
-- Start process:
-- @
-- carma-sms -u user -p password
-- @
-- 
-- Then send sms:
-- @
-- redis> hmset sms:1 from me phone 70001234567 msg \"test message\"
-- redis> lpush smspost sms:1
-- @
-- 
-- | SMS object
-- 
-- SMS object stored in redis has following format:
-- 
--   * from - sender
--
--   * phone - receiver, contains only digits
--
--   * msg - message in UTF-8
--
--   * action - filled by process, send or status
--
--   * msgid - filled by process, message id in smsdirect
--
--   * status - filled by process, message status, delivered, sent or send_error
-- 
--   * lasttry: timestamp of last try
--
--   * tries: number of tries
-- 
-- When carma-sms fails to send (or get status) sms, it pushes sms to retry-list (smspost:retry by default).
-- 
-- After that another thread will push these sms's back to \'smspost\'-list periodically until it succeeded or number of tries exceeded
--
module Main (
  main
  ) where

import Prelude hiding (log, catch)

import Control.Concurrent
import Data.List
import Data.Maybe (mapMaybe)
import qualified Data.Map as M
import Data.String
import qualified Data.Text as T
import qualified Database.Redis as R
import System.Environment
import System.Log

import CarmaSMS.Action (Action(..))
import CarmaSMS.Process

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
  takedrop _ [] = Nothing
  takedrop n xs = Just (take n xs, drop n xs)

-- convert arguments to map with replacing default values
args :: [(String, String)] -> [String] -> M.Map String String
args as s = arguments s `M.union` M.fromList as

rules :: String -> Rules
rules r = [
  parseRule_ (fromString $ "/: use " ++ r)]

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
      ("-r", "smspost:retry"),
      ("-retries", "10"),
      ("-d", "60"),
      ("-mps", "5"),
      ("-i", "1")]
    printUsage = mapM_ putStrLn $ [
      "Usage: carma-sms [flags] where",
      "  -u <user> - login for smsdirect",
      "  -p <pass> - password for smsdirect",
      "  -l <level> - log level, default is 'default', possible values are: trace, debug, default, silent",
      "  -k <key> - redis key for tasks, default is 'smspost'",
      "  -r <retry key> - redis key for retries, default is 'smspost:retry'",
      "  -retries <int> - max retries on sms actions",
      "  -d <seconds> - delta between tries",
      "  -mps <int> - HTTP requests per second",
      "  -i <id> - id of task-processing list, default is '1' (key will be 'smspost:1')",
      "",
      "Examples:",
      "  carma-sms -u user -p pass",
      "  carma-sms -u user -p pass -l trace",
      "  carma-sms -u user -p pass -l silent -k smspostlist"]
    main' flags = do
      conn <- R.connect R.defaultConnectInfo
      l <- newLog (constant (rules $ flag "-l")) [logger text (file "log/carma-sms.log")]

      _ <- forkIO $ retry l conn conf
      post l conn conf

      where
        conf = Action {
          actionUser = user,
          actionPass = pass,
          actionProcessId = fromString $ flag "-i",
          actionTaskList = fromString $ flag "-k",
          actionTaskId = "",
          actionTaskRetry = fromString $ flag "-retries",
          actionTaskRetries = iflag 10 "-m",
          actionTaskRetryDelta = iflag 60 "-d",
          actionMessagesPerSecond = iflag 5 "-mps",
          actionData = M.empty
        }

        flag = (flags M.!)
        iflag v = tryRead . flag where
          tryRead s = case reads s of
            [(i, "")] -> i
            _ -> v
        user :: T.Text
        user = fromString $ flag "-u"
        pass :: T.Text
        pass = fromString $ flag "-p"
