{-# LANGUAGE OverloadedStrings, FlexibleInstances #-}

module Main (
  main
  ) where

import Prelude hiding (log)

import Control.Monad.Reader
import qualified Data.ByteString.Char8 as C8
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Database.Redis as R
import System.Environment
import System.Log
import System.Worker.Redis

instance MonadLog m => MonadLog (ReaderT R.Connection m) where
  askLog = lift askLog

rules :: Rules
rules = []

main :: IO ()
main = do
  conn <- R.connect R.defaultConnectInfo
  l <- newLog (constant rules) [logger text (file "carma-sms.log")]
  withLog l $ runTask conn $ processTasks "smspost" "smspost:1" process onError
  where
    process i m = scope "sms" $ log Trace $ T.concat ["Processing ", T.decodeUtf8 i]
    onError i = scope "sms" $ log Error $ T.concat ["Unable to process: ", T.decodeUtf8 i]
