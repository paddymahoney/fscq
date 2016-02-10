{-# LANGUAGE MagicHash, UnboxedTuples #-}

module Disk where

import System.IO
import System.Posix.Types
import System.Posix.IO
import System.Posix.Unistd
import System.Posix.Files
import Word
import qualified Data.ByteString.Internal as BSI
import qualified GHC.Integer.GMP.Internals as GMPI
import qualified Foreign.C.Types
import GHC.Exts
import GHC.Prim
import Foreign.Marshal.Alloc
import Data.Word
import Data.IORef
import Data.Map
import Control.Concurrent.MVar

verbose :: Bool
verbose = False

reallySync :: Bool
reallySync = True

debugmsg :: String -> IO ()
debugmsg s =
  if verbose then
    putStrLn s
  else
    return ()

-- DiskStats counts the number of reads, writes, and syncs
data DiskStats =
  Stats !Word !Word !Word

-- FlushLog is used to track writes for empirical crash recovery testing
data FlushLog =
  FL ![(Word64, Coq_word)] ![[(Word64, Coq_word)]]
  -- The first list is the list of writes since the last flush
  -- The second list is the list of previous flushed write groups

-- VMem represents our variable-based memory model
type VMem = Data.Map.Map Int GHC.Prim.Any

data DiskState =
  S !Fd !(IORef DiskStats) !(IORef Bool) !(Maybe (IORef FlushLog)) !(IORef VMem) !(MVar ()) !(IORef (Data.Map.Map Coq_word [MVar ()]))

bumpRead :: IORef DiskStats -> IO ()
bumpRead sr = do
  Stats r w s <- readIORef sr
  writeIORef sr $ Stats (r+1) w s

bumpWrite :: IORef DiskStats -> IO ()
bumpWrite sr = do
  Stats r w s <- readIORef sr
  writeIORef sr $ Stats r (w+1) s

bumpSync :: IORef DiskStats -> IO ()
bumpSync sr = do
  Stats r w s <- readIORef sr
  writeIORef sr $ Stats r w (s+1)

logWrite :: Maybe (IORef FlushLog) -> Word64 -> Coq_word -> IO ()
logWrite Nothing _ _ = return ()
logWrite (Just fl) a v = do
  FL writes flushed <- readIORef fl
  writeIORef fl $ FL ((a, v) : writes) flushed

logFlush :: Maybe (IORef FlushLog) -> IO ()
logFlush Nothing = return ()
logFlush (Just fl) = do
  FL writes flushed <- readIORef fl
  writeIORef fl $ FL [] (writes : flushed)

-- For a more efficient array implementation, perhaps worth checking out:
-- http://www.macs.hw.ac.uk/~hwloidl/hackspace/ghc-6.12-eden-gumsmp-MSA-IFL13/libraries/dph/dph-base/Data/Array/Parallel/Arr/BUArr.hs

-- Some notes on memory-efficient file IO in Haskell:
-- http://stackoverflow.com/questions/26333815/why-do-hgetbuf-hputbuf-etc-allocate-memory

-- Snippets of ByteArray# manipulation code from GHC's
-- testsuite/tests/lib/integer/integerGmpInternals.hs

buf2i :: Word -> Ptr Word8 -> IO Integer
buf2i (W# nbytes) (GHC.Exts.Ptr a) = do
  GMPI.importIntegerFromAddr a nbytes 0#

i2buf :: Integer -> Foreign.C.Types.CSize -> Ptr Word8 -> IO ()
i2buf i nbytes (GHC.Exts.Ptr a) = do
  _ <- BSI.memset (GHC.Exts.Ptr a) 0 nbytes
  _ <- GMPI.exportIntegerToAddr i a 0#
  return ()

read_disk :: DiskState -> Coq_word -> IO Coq_word
read_disk ds (W a) = read_disk ds (W64 $ fromIntegral a)
read_disk (S fd sr _ _ _ _ _) (W64 a) = do
  debugmsg $ "read(" ++ (show a) ++ ")"
  bumpRead sr
  allocaBytes 4096 $ \buf -> do
    _ <- fdSeek fd AbsoluteSeek $ fromIntegral $ 4096*a
    cc <- fdReadBuf fd buf 4096
    if cc == 4096 then
      do
        i <- buf2i 4096 buf
        return $ W i
    else
      do
        error $ "read_disk: short read: " ++ (show cc) ++ " @ " ++ (show a)

write_disk :: DiskState -> Coq_word -> Coq_word -> IO ()
write_disk ds (W a) v = write_disk ds (W64 $ fromIntegral a) v
write_disk _ (W64 _) (W64 _) = error "write_disk: short value"
write_disk (S fd sr dirty fl _ _ _) (W64 a) (W v) = do
  -- maybeCrash
  debugmsg $ "write(" ++ (show a) ++ ")"
  bumpWrite sr
  writeIORef dirty True
  logWrite fl a (W v)
  allocaBytes 4096 $ \buf -> do
    _ <- fdSeek fd AbsoluteSeek $ fromIntegral $ 4096*a
    i2buf v 4096 buf
    cc <- fdWriteBuf fd buf 4096
    if cc == 4096 then
      return ()
    else
      do
        error $ "write_disk: short write: " ++ (show cc) ++ " @ " ++ (show a)

sync_disk :: DiskState -> Coq_word -> IO ()
sync_disk (S fd sr dirty fl _ _ _) a = do
  debugmsg $ "sync(" ++ (show a) ++ ")"
  isdirty <- readIORef dirty
  if isdirty then do
    bumpSync sr
    logFlush fl
    if reallySync then
      fileSynchroniseDataOnly fd
    else
      return ()
    writeIORef dirty False
  else
    return ()

trim_disk :: DiskState -> Coq_word -> IO ()
trim_disk _ a = do
  debugmsg $ "trim(" ++ (show a) ++ ")"
  return ()

clear_stats :: DiskState -> IO ()
clear_stats (S _ sr _ _ _ _ _) = do
  writeIORef sr $ Stats 0 0 0

get_stats :: DiskState -> IO DiskStats
get_stats (S _ sr _ _ _ _ _) = do
  s <- readIORef sr
  return s

init_disk :: FilePath -> IO DiskState
init_disk disk_fn = do
  fd <- openFd disk_fn ReadWrite (Just 0o666) defaultFileFlags
  sr <- newIORef $ Stats 0 0 0
  dirty <- newIORef False
  vm <- newIORef Data.Map.empty
  lock <- newMVar ()
  waiters <- newIORef Data.Map.empty
  return $ S fd sr dirty Nothing vm lock waiters

init_disk_crashlog :: FilePath -> IO DiskState
init_disk_crashlog disk_fn = do
  fd <- openFd disk_fn ReadWrite (Just 0o666) defaultFileFlags
  sr <- newIORef $ Stats 0 0 0
  dirty <- newIORef False
  fl <- newIORef $ FL [] []
  vm <- newIORef Data.Map.empty
  lock <- newMVar ()
  waiters <- newIORef Data.Map.empty
  return $ S fd sr dirty (Just fl) vm lock waiters

set_nblocks_disk :: DiskState -> Int -> IO ()
set_nblocks_disk (S fd _ _ _ _ _ _) nblocks = do
  setFdSize fd $ fromIntegral $ nblocks * 4096
  return ()

close_disk :: DiskState -> IO DiskStats
close_disk (S fd sr _ _ _ _ _) = do
  closeFd fd
  s <- readIORef sr
  return s

get_flush_log :: DiskState -> IO [[(Word64, Coq_word)]]
get_flush_log (S _ _ _ Nothing _ _ _) = return []
get_flush_log (S _ _ _ (Just fl) _ _ _) = do
  FL writes flushes <- readIORef fl
  return (writes : flushes)

clear_flush_log :: DiskState -> IO [[(Word64, Coq_word)]]
clear_flush_log (S _ _ _ Nothing _ _ _) = return []
clear_flush_log (S _ _ _ (Just fl) _ _ _) = do
  FL writes flushes <- readIORef fl
  writeIORef fl $ FL [] []
  return (writes : flushes)

get_var :: DiskState -> Int -> IO GHC.Prim.Any
get_var (S _ _ _ _ vm _ _) a = do
  m <- readIORef vm
  case Data.Map.lookup a m of
    Just x -> return x
    Nothing -> error $ "getting an unset variable " ++ (show a)

set_var :: DiskState -> Int -> GHC.Prim.Any -> IO ()
set_var (S _ _ _ _ vm _ _) a v = do
  m <- readIORef vm
  writeIORef vm (Data.Map.insert a v m)
  return ()

acquire_global_lock :: DiskState -> IO ()
acquire_global_lock (S _ _ _ _ _ lock _) = do
  v <- takeMVar lock
  return v

release_global_lock :: DiskState -> IO ()
release_global_lock (S _ _ _ _ _ lock _) = do
  putMVar lock ()
  return ()

print_stats :: DiskStats -> IO ()
print_stats (Stats r w s) = do
  putStrLn $ "Disk I/O stats:"
  putStrLn $ "Reads:  " ++ (show r)
  putStrLn $ "Writes: " ++ (show w)
  putStrLn $ "Syncs:  " ++ (show s)

register_waiter :: DiskState -> Coq_word -> MVar () -> IO ()
register_waiter (S _ _ _ _ _ _ wmapref) wchan waiter = do
  wmap <- readIORef wmapref
  old_waiters <- case Data.Map.lookup wchan wmap of
    Just waiters -> return waiters
    Nothing -> return []
  writeIORef wmapref (Data.Map.insert wchan (waiter : old_waiters) wmap)
  return ()

get_waiters :: DiskState -> Coq_word -> IO [MVar ()]
get_waiters (S _ _ _ _ _ _ wmapref) wchan = do
  wmap <- readIORef wmapref
  old_waiters <- case Data.Map.lookup wchan wmap of
    Just waiters -> return waiters
    Nothing -> return []
  writeIORef wmapref (Data.Map.delete wchan wmap)
  return old_waiters
