{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Mafia.IO
  ( -- * Directory Operations
    ListingOptions(..)
  , getDirectoryListing
  , getDirectoryContents
  , createDirectoryIfMissing
  , removeDirectoryRecursive
  , setCurrentDirectory
  , getCurrentDirectory
  , makeRelativeToCurrentDirectory
  , tryMakeRelativeToCurrent
  , canonicalizePath

    -- * Existence Tests
  , doesFileExist
  , doesDirectoryExist

    -- * Timestamps
  , getModificationTime

    -- * File Operations
  , readUtf8
  , readBytes
  , writeUtf8
  , writeBytes
  , removeFile
  , copyFile

    -- * Environment
  , findExecutable
  , lookupEnv

    -- * Pre-defined directories
  , getHomeDirectory

    -- * Concurrency
  , mapConcurrentlyE
  ) where

import qualified Control.Concurrent.Async as Async
import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Trans.Maybe (MaybeT(..))

import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Time (UTCTime)

import           Mafia.Path

import           P

import           System.IO (IO)
import qualified System.Directory as Directory
import qualified System.Environment as Environment

import           X.Control.Monad.Trans.Either (EitherT, runEitherT, hoistEither)

------------------------------------------------------------------------
-- Directory Operations

data ListingOptions = Recursive | RecursiveDepth Int
  deriving (Eq, Ord, Show)

getDirectoryListing :: MonadIO m => ListingOptions -> Directory -> m [Path]
getDirectoryListing (RecursiveDepth n) _ | n < 0 = return []
getDirectoryListing options path = do
    entries    <- fmap (path </>) `liftM` getDirectoryContents path
    subEntries <- mapM down entries
    return (concat (entries : subEntries))
  where
    down entry = do
      isDir <- doesDirectoryExist entry
      if isDir
         then getDirectoryListing options' entry
         else return []

    options' = case options of
      Recursive        -> Recursive
      RecursiveDepth n -> RecursiveDepth (n-1)

getDirectoryContents :: MonadIO m => Directory -> m [Path]
getDirectoryContents path = liftIO $ do
  entries <- Directory.getDirectoryContents (T.unpack path)
  let interesting x = not (x == "." || x == "..")
  return . filter interesting
         . fmap T.pack
         $ entries

createDirectoryIfMissing :: MonadIO m => Bool -> Directory -> m ()
createDirectoryIfMissing parents dir =
  liftIO (Directory.createDirectoryIfMissing parents (T.unpack dir))

removeDirectoryRecursive :: MonadIO m => Directory -> m ()
removeDirectoryRecursive dir =
  liftIO (Directory.removeDirectoryRecursive (T.unpack dir))

setCurrentDirectory :: MonadIO m => Directory -> m ()
setCurrentDirectory dir = liftIO (Directory.setCurrentDirectory (T.unpack dir))

getCurrentDirectory :: MonadIO m => m Directory
getCurrentDirectory = T.pack `liftM` liftIO Directory.getCurrentDirectory

makeRelativeToCurrentDirectory :: MonadIO m => Path -> m (Maybe Path)
makeRelativeToCurrentDirectory path = do
  current <- getCurrentDirectory
  absPath <- T.pack `liftM` liftIO (Directory.makeAbsolute (T.unpack path))
  return (makeRelative current absPath)

tryMakeRelativeToCurrent :: MonadIO m => Directory -> m Directory
tryMakeRelativeToCurrent dir =
  fromMaybe dir `liftM` makeRelativeToCurrentDirectory dir

canonicalizePath :: MonadIO m => Path -> m Path
canonicalizePath path =
  T.pack `liftM` liftIO (Directory.canonicalizePath (T.unpack path))

------------------------------------------------------------------------
-- Existence Tests

doesFileExist :: MonadIO m => File -> m Bool
doesFileExist path = liftIO (Directory.doesFileExist (T.unpack path))

doesDirectoryExist :: MonadIO m => Directory -> m Bool
doesDirectoryExist path = liftIO (Directory.doesDirectoryExist (T.unpack path))

------------------------------------------------------------------------
-- Timestamps

getModificationTime :: MonadIO m => File -> m UTCTime
getModificationTime path = liftIO (Directory.getModificationTime (T.unpack path))

------------------------------------------------------------------------
-- File I/O

readUtf8 :: MonadIO m => File -> m (Maybe Text)
readUtf8 path = runMaybeT $ do
  bytes <- MaybeT (readBytes path)
  return (T.decodeUtf8 bytes)

writeUtf8 :: MonadIO m => File -> Text -> m ()
writeUtf8 path text = liftIO (B.writeFile (T.unpack path) (T.encodeUtf8 text))

readBytes :: MonadIO m => File -> m (Maybe ByteString)
readBytes path = liftIO $ do
  exists <- doesFileExist path
  case exists of
    False -> return Nothing
    True  -> Just `liftM` B.readFile (T.unpack path)

writeBytes :: MonadIO m => File -> ByteString -> m ()
writeBytes path bytes = liftIO (B.writeFile (T.unpack path) bytes)

removeFile :: MonadIO m => File -> m ()
removeFile path = liftIO (Directory.removeFile (T.unpack path))

copyFile :: MonadIO m => File -> File -> m ()
copyFile src dst = liftIO (Directory.copyFile (T.unpack src) (T.unpack dst))

------------------------------------------------------------------------
-- Environment

findExecutable :: MonadIO m => Text -> m (Maybe File)
findExecutable name = liftIO $ do
  path <- Directory.findExecutable (T.unpack name)
  return (fmap T.pack path)

lookupEnv :: MonadIO m => Text -> m (Maybe Text)
lookupEnv key = liftIO $ do
  value <- Environment.lookupEnv (T.unpack key)
  return (fmap T.pack value)

------------------------------------------------------------------------
-- Pre-defined directories

getHomeDirectory :: MonadIO m => m Directory
getHomeDirectory = T.pack `liftM` liftIO Directory.getHomeDirectory

------------------------------------------------------------------------
-- Concurrency

mapConcurrentlyE :: Traversable t => (a -> EitherT x IO b) -> t a -> EitherT x IO (t b)
mapConcurrentlyE io xs = do
  ys <- liftIO (Async.mapConcurrently (runEitherT . io) xs)
  hoistEither (sequence ys)
