module Antiope.SQS
  ( QueueUrl(..)
  , SQSError(..)
  , HasReceiptHandle
  , ConsumerMode(..)
  , ConsumerResult(..)
  , readQueue
  , readQueue'
  , drainQueue
  , drainQueue'
  , ackMessage
  , ackMessages
  , queueSource
  , forAllMessages
  , forAllMessages'
  , defaultReceiveMessage

  -- * Re-exports
  , Message
  , mBody, mMD5OfBody, mMessageId, mReceiptHandle, mAttributes
  ) where

import Control.Lens
import Control.Monad            (forM, forM_, join, void)
import Control.Monad.IO.Unlift  (MonadUnliftIO)
import Control.Monad.Loops      (unfoldWhileM)
import Control.Monad.Trans      (lift)
import Data.Coerce              (coerce)
import Data.Conduit
import Data.Conduit.Combinators (yieldMany)
import Data.List.Split          (chunksOf)
import Data.Maybe               (catMaybes)
import Data.Text                (pack)
import Network.AWS              (HasEnv, MonadAWS, runAWS, runResourceT)
import Network.AWS.SQS

import Antiope.SQS.Types

import qualified Network.AWS as AWS

defaultReceiveMessage :: QueueUrl -> ReceiveMessage
defaultReceiveMessage (QueueUrl url)
  = receiveMessage url
  & rmWaitTimeSeconds ?~ 10
  & rmMaxNumberOfMessages ?~ 10

-- | Reads the specified SQS queue once returning a bath of messages
readQueue :: MonadAWS m
  => QueueUrl
  -> m [Message]
readQueue = readQueue' . defaultReceiveMessage

-- | Reads the specified SQS queue once returning a bath of messages
readQueue' :: MonadAWS m
  => ReceiveMessage
  -> m [Message]
readQueue' recMsg = do
  -- max wait time allowed by aws is 20sec, max number messages to recieve is 10
  resp <- AWS.send recMsg
  return $ resp ^. rmrsMessages

-- | Reads the specified SQS queue until it is empty and returns a list of messages
drainQueue :: MonadAWS m
  => QueueUrl
  -> m [Message]
drainQueue = drainQueue' . defaultReceiveMessage

-- | Reads the specified SQS queue until it is empty and returns a list of messages
drainQueue' :: MonadAWS m
  => ReceiveMessage
  -> m [Message]
drainQueue' recMsg = join <$> unfoldWhileM (not . null) (readQueue' recMsg)

-- | Acknowledges a single SQS message
ackMessage :: (MonadAWS m, HasReceiptHandle msg)
  => QueueUrl
  -> msg
  -> m (Either SQSError ())
ackMessage q msg = ackMessages q [msg]

-- | Acknowledges a group of SQS messages
ackMessages :: (MonadAWS m, HasReceiptHandle msg)
  => QueueUrl
  -> [msg]
  -> m (Either SQSError ())
ackMessages (QueueUrl queueUrl) msgs = do
  let receipts' = msgs ^.. each . to getReceiptHandle & catMaybes
  let maxBatchSize = 10 -- Amazon enforces this
  results <- forM (chunksOf maxBatchSize receipts') $ \receipts -> do
    -- each dmbr needs an ID. just use the list index.
    let dmbres = (\(r, i) -> deleteMessageBatchRequestEntry (pack (show i)) r) <$> zip (coerce receipts) ([0..] :: [Int])
    resp <- AWS.send $ deleteMessageBatch queueUrl & dmbEntries .~ dmbres
    -- only acceptable if no errors.
    if resp ^. dmbrsResponseStatus == 200
      then case resp ^. dmbrsFailed of
          [] -> return $ Right ()
          _  -> return $ Left DeleteMessageBatchError
      else return $ Left DeleteMessageBatchError
  pure $ sequence_ results


-- | Reads from an SQS indefinitely, producing messages into a conduit
queueSource :: MonadAWS m => QueueUrl -> ConduitT () Message m ()
queueSource (QueueUrl queueUrl) = do
  m <- lift $ AWS.send $ receiveMessage queueUrl & rmWaitTimeSeconds ?~ 10 & rmMaxNumberOfMessages ?~ 10
  yieldMany (m ^. rmrsMessages)
  queueSource (QueueUrl queueUrl)

forAllMessages :: (MonadUnliftIO m, HasEnv env)
  => env
  -> QueueUrl
  -> ConsumerMode
  -> (Message -> m ConsumerResult)
  -> m ()
forAllMessages env queue = forAllMessages' env (defaultReceiveMessage queue)

forAllMessages' :: (MonadUnliftIO m, HasEnv env)
  => env
  -> ReceiveMessage
  -> ConsumerMode
  -> (Message -> m ConsumerResult)
  -> m ()
forAllMessages' env recMsg mode process = go
  where
    go = do
      msgs <- runResourceT $ runAWS env (readQueue' recMsg)
      case (mode, msgs) of
        (Drain, []) -> pure ()
        _           -> processBatch msgs >> go
    processBatch msgs =
      forM_ msgs $ \msg -> do
        res <- process msg
        case res of
          Ack  -> void . runResourceT . runAWS env $ ackMessage (QueueUrl $ recMsg ^. rmQueueURL) msg
          Nack -> pure ()
