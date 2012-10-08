{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}

module Action (
  ActionM,
  action,
  runAction,
  noAction,
  sendAction,
  statusAction
  ) where

import Prelude hiding (log, catch)

import qualified Control.Exception as E
import Control.Monad.CatchIO
import Control.Monad.Reader

import qualified Data.ByteString.Char8 as C8
import qualified Data.Map as M
import Data.String
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

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
  actionData :: M.Map T.Text T.Text }

newtype ActionM m a = ActionM {
  actionM :: ReaderT Action m a }
    deriving (Functor, Monad, MonadIO, MonadCatchIO, MonadReader Action, MonadTrans)

instance MonadLog m => MonadLog (ActionM m) where
  askLog = lift askLog

instance MonadTask m => MonadTask (ActionM m) where
  inTask = lift . inTask

action :: (MonadLog m, MonadTask m) => T.Text -> T.Text -> T.Text -> T.Text -> M.Map T.Text T.Text -> m ()
action u p tl ti d = runReaderT (actionM runAction) $ Action u p tl ti d

runAction :: (MonadLog m, MonadTask m) => ActionM m ()
runAction = ignoreError $ do
  act <- asks (maybe "send" id . M.lookup "action" . actionData)
  maybe (noAction act) id $ M.lookup act actions
  where
    actions = M.fromList [
      ("send", sendAction),
      ("status", statusAction)]

noAction :: (MonadLog m, MonadTask m) => T.Text -> ActionM m ()
noAction a = log Error $ T.concat ["Invalid action: ", a]

sendAction :: (MonadLog m, MonadTask m) => ActionM m ()
sendAction = scope "send" $ catch sendAction' onError where
  sendAction' = do
    u <- asks actionUser
    p <- asks actionPass
    i <- asks (T.encodeUtf8 . actionTaskId)
    tasks <- asks (T.encodeUtf8 . actionTaskList)

    from <- askData "from"
    to <- askData "phone"
    msg <- askData "msg"
    mid <- smsdirect' u p $ submitMessage from (phone to) msg Nothing
    log Trace $ T.concat ["Message id: ", fromString $ show mid]
    _ <- inTask $ do
      _ <- R.hmset i [
        ("msgid", C8.pack $ show mid),
        ("status", "sent"),
        ("action", "status")]
      R.lpush tasks [i]
    return ()
  onError :: (MonadLog m, MonadTask m) => E.SomeException -> ActionM m ()
  onError _ = do
    i <- asks (T.encodeUtf8 . actionTaskId)
    _ <- inTask $ R.hmset i [("status", "send_error")]
    return ()

statusAction :: (MonadLog m, MonadTask m) => ActionM m ()
statusAction = do
  u <- asks actionUser
  p <- asks actionPass
  i <- asks (T.encodeUtf8 . actionTaskId)
  tasks <- asks (T.encodeUtf8 . actionTaskList)

  msgid <- askData "msgid"
  st <- smsdirect' u p $ statusMessage (read . T.unpack $ msgid)
  case st of
    0 -> inTask $ R.hmset i [("status", "delivered"), ("action", "")] >> return ()
    1 -> inTask $ R.lpush tasks [i] >> return ()
    _ -> return ()

askData :: (MonadLog m, MonadTask m) => T.Text -> ActionM m T.Text
askData t = do
  m <- asks actionData
  case M.lookup t m of
    Nothing -> do
      log Error $ T.concat ["No field '", t, "'"]
      error "No field"
    Just v -> do
      log Trace $ T.concat [t, " = ", v]
      return  v

-- Logs error and return
smsdirect' :: MonadLog m => T.Text -> T.Text -> SMSDirect.Command a -> m a
smsdirect' u p cmd = scope "direct" $ do
  log Trace $ T.concat ["URL: ", fromString $ url u p cmd]
  v <- liftIO $ smsdirect u p cmd
  case v of
    Left code -> do
      log Error $ T.concat ["Error code: ", fromString $ show code]
      error "sms direct fail"
    Right x -> return x

ignoreError :: (MonadLog m) => m () -> m ()
ignoreError act = catch act onError where
  onError :: (MonadLog m) => E.SomeException -> m ()
  onError _ = return ()
