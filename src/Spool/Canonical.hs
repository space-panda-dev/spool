{-# LANGUAGE OverloadedStrings #-}

-- | The one encoding of everything Spool writes.
module Spool.Canonical
  ( canonical
  , encode
  ) where

import Data.Aeson (ToJSON (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import Data.List (sortOn)

-- | The canonical bytes of anything the protocol writes.
encode :: ToJSON a => a -> BL.ByteString
encode = canonical . toJSON

-- | One line, no space outside a string, and the keys of every object in
-- code point order, so that equal values are equal bytes. The order is
-- given here and not left to the JSON library, whose own order depends on
-- how it was built.
canonical :: A.Value -> BL.ByteString
canonical value = case value of
  A.Null -> "null"
  A.Bool True -> "true"
  A.Bool False -> "false"
  A.Number number -> A.encode number
  A.String text -> A.encode text
  A.Array values -> "[" <> joinComma (map canonical (toList values)) <> "]"
  A.Object object -> "{" <> joinComma (map encodePair ordered) <> "}"
    where
      ordered = sortOn (K.toText . fst) (KM.toList object)
      encodePair (key, child) = A.encode (K.toText key) <> ":" <> canonical child

joinComma :: [BL.ByteString] -> BL.ByteString
joinComma [] = ""
joinComma (firstValue : rest) = firstValue <> foldMap ("," <>) rest
