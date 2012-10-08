{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main (
  main
  ) where

import Prelude hiding (log, catch)

import Control.Monad.Trans
import Control.Concurrent
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

import Action

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

instance MonadLog m => MonadLog (TaskMonad m) where
  askLog = lift askLog

rules :: String -> Rules
rules r = [
  parseRule_ (fromString $ "/: use " ++ r)]

-- | SMS format
-- from: sender
-- phone: receiver
-- msg: message
-- action: action to perform on sms (send/status)
-- msgid: message id in smsdirect
-- status: status of message (delivered/sent/send_error)

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
          action user pass (fromString $ flag "-k") (T.decodeUtf8 i) (M.mapKeys T.decodeUtf8 . M.map T.decodeUtf8 $ m)
          liftIO $ threadDelay 200000 -- 5 messages per second

        onError i = scope "sms" $ log Error $ T.concat ["Unable to process: ", T.decodeUtf8 i]
        flag = (flags M.!)
        user :: T.Text
        user = fromString $ flag "-u"
        pass :: T.Text
        pass = fromString $ flag "-p"
