{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module CarmaSMS.Process (
  post,
  retry
  ) where

import Prelude hiding (log)

import Control.Concurrent
import Control.Monad.Error
import Data.ByteString (ByteString)
import Data.String
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Database.Redis as R
import System.Log
import System.Worker.Redis

import CarmaSMS.Action (Action(..))
import qualified CarmaSMS.Action as A

instance MonadLog m => MonadLog (TaskMonad m) where
  askLog = lift askLog

-- | Post SMS process
post :: Log -> R.Connection -> Action -> IO ()
post l conn a = withLog l $ do
  scope "sms" $ log Info $ T.concat ["Starting sms for user ", actionUser a, " with password ", actionPass a]
  e <- runErrorT $ runTask conn $ processTasks
    (T.encodeUtf8 . actionTaskList $ a)
    (T.encodeUtf8 $ T.concat [actionTaskList a, ":", actionProcessId a])
    process
    onError
  case e of
    Left str -> scope "sms" $ do
      log Fatal $ T.concat ["Fatal error: ", fromString str]
      return ()
    _ -> return ()
  where
    process i m = scopeM "sms" $ scope (T.decodeUtf8 i) $ do
      A.action $ a {
        actionTaskId = T.decodeUtf8 i,
        actionData = mapData $ m
      }
      liftIO $ threadDelay $ 1000000 `div` (actionMessagesPerSecond a)
    onError i = scopeM "sms" $ log Error $ T.concat ["Unable to process: ", T.decodeUtf8 i]

-- | Retry SMS process
retry :: Log -> R.Connection -> Action -> IO ()
retry l conn a = withLog l $ do
  scope "retry" $ log Info "Retry process started"
  e <- runErrorT $ runTask conn $ processTasks
    (T.encodeUtf8 . actionTaskRetry $ a)
    (T.encodeUtf8 $ T.concat [actionTaskRetry a, ":", actionProcessId a])
    process
    onError
  case e of
    Left str -> scope "retry" $ do
      log Fatal $ T.concat ["Fatal error: ", fromString str]
      return ()
    _ -> return ()
  where
    process i m = scopeM "retry" $ scope (T.decodeUtf8 i) $ do
      A.retry $ a {
        actionTaskId = T.decodeUtf8 i,
        actionData = mapData $ m
      }
    onError i = scopeM "retry" $ log Error $ T.concat ["Unable to process: ", T.decodeUtf8 i]

mapData :: M.Map ByteString ByteString -> M.Map T.Text T.Text
mapData = M.mapKeys T.decodeUtf8 . M.map T.decodeUtf8
