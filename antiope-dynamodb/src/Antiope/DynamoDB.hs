{-# LANGUAGE ScopedTypeVariables #-}

module Antiope.DynamoDB
( TableName(..)
, dynamoPutItem
, dynamoQuery
, module Network.AWS.DynamoDB
) where

import Antiope.Core           (ToText (..))
import Antiope.DynamoDB.Types (TableName (TableName))
import Control.Lens
import Data.HashMap.Strict    (HashMap)
import Data.Text              (Text)
import Network.AWS            (MonadAWS)
import Network.AWS.DynamoDB

import qualified Network.AWS as AWS

dynamoPutItem :: MonadAWS m
  => TableName
  -> HashMap Text AttributeValue
  -> m PutItemResponse
dynamoPutItem table item = AWS.send $ putItem (table & toText) & piItem .~ item

dynamoQuery :: MonadAWS m
  => TableName
  -> (Query
  -> Query)
  -> m QueryResponse
dynamoQuery table f = AWS.send $ f $ query (table & toText)
