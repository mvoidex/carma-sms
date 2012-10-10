{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving, FlexibleInstances, MultiParamTypeClasses, UndecidableInstances, FlexibleContexts #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module CarmaSMS.Action (
  Action(..),
  ActionM,
  action,
  runAction,
  noAction,
  sendAction,
  statusAction
  ) where

import Prelude hiding (log, catch)

import Control.Monad.CatchIO
import Control.Monad.Reader
import Control.Monad.Error

import qualified Data.ByteString.Char8 as C8
import qualified Data.Map as M
import Data.String
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time.Clock.POSIX

import qualified Database.Redis as R
import System.Worker.Redis
import System.Log
import SMSDirect

-- | Action data
data Action = Action {
  actionUser :: T.Text,
  actionPass :: T.Text,
  actionTaskList :: T.Text,
  actionTaskId :: T.Text,
  actionTaskRetry :: T.Text,
  actionTaskRetries :: Int,
  actionTaskRetryDelta :: Int,
  actionData :: M.Map T.Text T.Text }

-- | Action monad
newtype ActionM m a = ActionM {
  actionM :: ReaderT Action m a }
    deriving (Functor, Monad, MonadIO, MonadCatchIO, MonadReader Action, MonadTrans)

data ActionError =
  SMSDirectError ErrorCode |
  OtherError String
    deriving (Eq, Ord, Read, Show)

instance Error ActionError where
  strMsg = OtherError
  noMsg = OtherError noMsg

instance MonadLog m => MonadLog (ActionM m) where
  askLog = lift askLog

instance MonadTask m => MonadTask (ActionM m) where
  inTask = lift . inTask

instance (Error e, MonadTask m) => MonadTask (ErrorT e m) where
  inTask = lift . inTask

instance (Error e, MonadLog m) => MonadLog (ErrorT e m) where
  askLog = lift askLog

instance MonadError e m => MonadError e (ActionM m) where
  throwError = ActionM . throwError
  catchError (ActionM a) h = ActionM $ catchError a (actionM . h)

-- | Run action by user, password, task-list, task-id, task-retry-list and data
action :: (MonadLog m, MonadTask m, MonadError String m) => Action -> m ()
action a = runReaderT (actionM runAction) a

-- | Run action
runAction :: (MonadLog m, MonadTask m, MonadReader Action m, MonadError String m) => m ()
runAction = do
  act <- asks (maybe "send" id . M.lookup "action" . actionData)
  res <- runErrorT $ maybe (noAction act) id $ M.lookup act actions
  case res of
    Left (SMSDirectError 200) -> do
      log Fatal "Invalid login or password"
      throwError . strMsg $ "Invalid login or password"
    _ -> catchError retry' retryError where
      retry' = do
        b <- retry
        when (not b) $ log Warning "Number of retries exceeded"
      retryError s = do
        log Error $ T.concat ["Unable to retry: ", fromString s]
  where
    actions = M.fromList [
      ("send", sendAction),
      ("status", statusAction)]

-- | Catch-all action
noAction :: (MonadLog m, MonadTask m, MonadReader Action m) => T.Text -> m ()
noAction a = log Error $ T.concat ["Invalid action: ", a]

-- | Send SMS
sendAction :: (MonadLog m, MonadTask m, MonadReader Action m, MonadError ActionError m) => m ()
sendAction = scope "send" $ catchError sendAction' onError where
  sendAction' = do
    u <- asks actionUser
    p <- asks actionPass
    i <- asks (T.encodeUtf8 . actionTaskId)
    tasks <- asks (T.encodeUtf8 . actionTaskList)

    from <- askData "from"
    to <- askData "phone"
    msg <- askData "msg"
    from' <- either (throwError . strMsg) return $ sender from
    to' <- either (throwError . strMsg) return $ phone to

    mid <- smsdirect' u p $ submitMessage from' to' msg Nothing
    log Trace $ T.concat ["Message id: ", fromString $ show mid]
    _ <- inTask $ do
      _ <- R.hmset i [
        ("msgid", C8.pack $ show mid),
        ("status", "sent"),
        ("action", "status")]
      R.lpush tasks [i]
    return ()
  onError :: (MonadLog m, MonadTask m, MonadReader Action m, MonadError ActionError m) => ActionError -> m ()
  onError e = do
    log Error $ T.concat ["Unable to send message: ", fromString $ show e]
    i <- asks (T.encodeUtf8 . actionTaskId)
    _ <- inTask $ R.hmset i [("status", "send_error")]
    throwError e

-- | Retrieve status of SMS
statusAction :: (MonadLog m, MonadTask m, MonadReader Action m, MonadError ActionError m) => m ()
statusAction = scope "status" $ do
  u <- asks actionUser
  p <- asks actionPass
  i <- asks (T.encodeUtf8 . actionTaskId)
  tasks <- asks (T.encodeUtf8 . actionTaskList)

  msgid <- askData "msgid"
  st <- smsdirect' u p $ statusMessage (read . T.unpack $ msgid)
  case st of
    Just 0 -> inTask $ R.hmset i [("status", "delivered"), ("action", "")] >> return ()
    Just 1 -> inTask $ R.lpush tasks [i] >> return ()
    _ -> return ()

-- | Get field of data
askData :: (MonadLog m, MonadTask m, MonadReader Action m, MonadError ActionError m) => T.Text -> m T.Text
askData t = do
  m <- asks actionData
  case M.lookup t m of
    Nothing -> throwError $ strMsg $ "No field '" ++ T.unpack t ++ "'"
    Just v -> do
      log Trace $ T.concat [t, " = ", v]
      return  v

-- | Logs error and return
smsdirect' :: (MonadLog m, MonadError ActionError m) => T.Text -> T.Text -> SMSDirect.Command a -> m a
smsdirect' u p cmd = do
  log Trace $ T.concat ["URL: ", fromString $ url u p cmd]
  v <- liftIO $ smsdirect u p cmd
  case v of
    Left code -> throwError $ SMSDirectError code
    Right x -> return x

-- | Retry sms, returns False, if number of tries exceeded
--
-- Increases \'tries\' field, sets \'lasttry\' to now and pushes task id to task-retry-list
--
retry :: (MonadLog m, MonadTask m, MonadError String m, MonadReader Action m) => m Bool
retry = scope "retry" $ do
  triesStr <- asks (M.lookup "tries" . actionData)
  triesNum <- maybe (return 0) tryRead triesStr
  i <- asks (T.encodeUtf8 . actionTaskList)
  retryList <- asks (T.encodeUtf8 . actionTaskRetry)
  maxRetries <- asks actionTaskRetries

  if triesNum >= maxRetries
    then return False
    else do
      tm <- liftIO $ liftM floor getPOSIXTime

      _ <- inTask $ do
        _ <- R.hmset i [
          ("tries", fromString . show . succ $ triesNum),
          ("lasttry", fromString . show $ (tm :: Int))]
        R.lpush retryList [i]
      return True
  where
    tryRead :: (MonadError String m) => T.Text -> m Int
    tryRead s = case reads (T.unpack s) of
      [(i, "")] -> return i
      _ -> throwError . strMsg $ "Unable to parse 'tries' field: " ++ T.unpack s
