-- Type.hs:
-- //./Type.hs//

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Main where

import Crypto.Hash.MD5 (hash)
import Control.Monad (when, forM_)
import Data.FileEmbed
import Data.List (partition, isPrefixOf)
import Data.Time.Clock
import Data.Word
import Foreign.C.Types
import Foreign.LibFFI
import Foreign.LibFFI.Types
import GHC.Conc
import HVML.Collapse
import HVML.Compile
import HVML.Extract
import HVML.Inject
import HVML.Parse
import HVML.Reduce
import HVML.Show
import HVML.Type
import System.CPUTime
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode(ExitSuccess, ExitFailure))
import System.IO
import System.IO (readFile)
import System.IO.Error (tryIOError)
import System.Posix.DynamicLinker
import System.Process (callCommand)
import Text.Printf
import Data.IORef
import qualified Data.ByteString.Char8 as C8
import qualified Data.Map.Strict as MS

runtime_c :: String
runtime_c = $(embedStringFile "./src/HVML/Runtime.c")

-- Main
-- ----

data RunMode
  = Normalize
  | Collapse
  | Search
  deriving Eq

main :: IO ()
main = do
  args <- getArgs
  result <- case args of
    ("run" : file : rest) -> do
      let (flags, strArgs) = partition ("-" `isPrefixOf`) rest
      let compiled = "-c" `elem` flags
      let collapse = "-C" `elem` flags
      let search   = "-S" `elem` flags
      let stats    = "-s" `elem` flags
      let debug    = "-d" `elem` flags
      let mode | collapse  = Collapse
               | search    = Search
               | otherwise = Normalize
      cliRun file debug compiled mode stats strArgs
    ["help"] -> printHelp
    _ -> printHelp
  case result of
    Left err -> do
      putStrLn err
      exitWith (ExitFailure 1)
    Right _ -> do
      exitWith ExitSuccess

printHelp :: IO (Either String ())
printHelp = do
  putStrLn "HVM-Lazy usage:"
  putStrLn "  hvml help       # Shows this help message"
  putStrLn "  hvml run <file> [flags] [string args...] # Evals main"
  putStrLn "    -t # Returns the type (experimental)"
  putStrLn "    -c # Runs with compiled mode (fast)"
  putStrLn "    -C # Collapse the result to a list of λ-Terms"
  putStrLn "    -S # Search (collapse, then print the 1st λ-Term)"
  putStrLn "    -s # Show statistics"
  putStrLn "    -d # Print execution steps (debug mode)"
  return $ Right ()

-- CLI Commands
-- ------------

cliRun :: FilePath -> Bool -> Bool -> RunMode -> Bool -> [String] -> IO (Either String ())
cliRun filePath debug compiled mode showStats strArgs = do
  -- Initialize the HVM
  hvmInit
  code <- readFile filePath
  -- Wrap the main function with any cli arguments
  let codeA = code ++ "\n@__main = @main(" ++ unwords (map (\s -> "\"" ++ s ++ "\"") strArgs) ++ ")"
  book <- doParseBook codeA
  -- Create the C file content
  let decls = compileHeaders book
  let funcs = map (\ (fid, _) -> compile book fid) (MS.toList (fidToFun book))
  let mainC = unlines $ [runtime_c] ++ [decls] ++ funcs ++ [genMain book]
  -- Set constructor arities, case length and ADT ids
  forM_ (MS.toList (cidToAri book)) $ \ (cid, ari) -> do
    hvmSetCari cid (fromIntegral ari)
  forM_ (MS.toList (cidToLen book)) $ \ (cid, len) -> do
    hvmSetClen cid (fromIntegral len)
  forM_ (MS.toList (cidToADT book)) $ \ (cid, adt) -> do
    hvmSetCadt cid (fromIntegral adt)
  forM_ (MS.toList (fidToFun book)) $ \ (fid, ((_, args), _)) -> do
    hvmSetFari fid (fromIntegral $ length args)
  -- Compile to native
  when compiled $ do
    -- Try to use a cached .so file
    callCommand "mkdir -p .build"
    let fName = last $ words $ map (\c -> if c == '/' then ' ' else c) filePath
    let cPath = ".build/" ++ fName ++ ".c"
    let oPath = ".build/" ++ fName ++ ".so"
    oldFile <- tryIOError (readFile cPath)
    oldLib  <- tryIOError (dlopen oPath [RTLD_NOW])
    bookLib <- case (oldFile, oldLib) of
      -- Use the cache if the hash of the .c file matches
      (Right old, Right lib) | hash (C8.pack old) == hash (C8.pack mainC) -> do
        return lib
      -- Otherwise, recompile
      (old, lib) -> do
        either (\_ -> return ()) dlclose lib
        writeFile cPath mainC
        callCommand $ "gcc -O2 -fPIC -shared " ++ cPath ++ " -o " ++ oPath
        dlopen oPath [RTLD_NOW]
    -- Register compiled functions
    forM_ (MS.keys (fidToFun book)) $ \ fid -> do
      funPtr <- dlsym bookLib (mget (fidToNam book) fid ++ "_f")
      hvmDefine fid funPtr
    -- Link compiled state
    hvmGotState <- hvmGetState
    hvmSetState <- dlsym bookLib "hvm_set_state"
    callFFI hvmSetState retVoid [argPtr hvmGotState]
  -- Abort when main isn't present
  when (not $ MS.member "main" (namToFid book)) $ do
    putStrLn "Error: 'main' not found."
    exitWith (ExitFailure 1)
  -- Abort when wrong number of strArgs
  let ((_, mainArgs), _) = mget (fidToFun book) (mget (namToFid book) "main")
  when (length strArgs /= length mainArgs) $ do
    putStrLn $ "Error: 'main' expects " ++ show (length mainArgs)
              ++ " arguments, found " ++ show (length strArgs)
    exitWith (ExitFailure 1)
  -- Normalize main
  init <- getCPUTime
  root <- doInjectCoreAt book (Ref "__main" (mget (namToFid book) "__main") []) 0 []
  rxAt <- if compiled
    then return (reduceCAt debug)
    else return (reduceAt debug)
  vals <- if mode == Collapse || mode == Search
    then doCollapseFlatAt rxAt book 0
    else do
      core <- doExtractCoreAt rxAt book 0
      return [(doLiftDups core)]
  -- Print all collapsed results
  when (mode == Collapse) $ do
    lastItrs <- newIORef 0
    forM_ vals $ \ term -> do
      currItrs <- getItr
      prevItrs <- readIORef lastItrs
      -- printf "%012d %012d %s\n" currItrs (currItrs - prevItrs) (showCore term)
      printf "%s\n" (showCore term)
      writeIORef lastItrs currItrs
  -- Prints just the first collapsed result
  when (mode == Search || mode == Normalize) $ do
    putStrLn $ showCore (head vals)
  when (mode /= Normalize) $ do
    putStrLn ""
  -- Prints total time
  end <- getCPUTime
  -- Show stats
  when showStats $ do
    itrs <- getItr
    size <- getLen
    let time = fromIntegral (end - init) / (10^12) :: Double
    let mips = (fromIntegral itrs / 1000000.0) / time
    printf "WORK: %llu interactions\n" itrs
    printf "TIME: %.7f seconds\n" time
    printf "SIZE: %llu nodes\n" size
    printf "PERF: %.3f MIPS\n" mips
    return ()
  -- Finalize
  hvmFree
  return $ Right ()

genMain :: Book -> String
genMain book =
  let mainFid = mget (namToFid book) "__main"
      registerFuncs = unlines ["  hvm_define(" ++ show fid ++ ", " ++ mget (fidToNam book) fid ++ "_f);" | fid <- MS.keys (fidToFun book)]
  in unlines
    [ "int main() {"
    , "  hvm_init();"
    , registerFuncs
    , "  clock_t start = clock();"
    , "  Term root = term_new(REF, "++show mainFid++", 0);"
    , "  normal(root);"
    , "  double time = (double)(clock() - start) / CLOCKS_PER_SEC * 1000;"
    , "  printf(\"WORK: %llu interactions\\n\", get_itr());"
    , "  printf(\"TIME: %.3fs seconds\\n\", time / 1000.0);"
    , "  printf(\"SIZE: %u nodes\\n\", get_len());"
    , "  printf(\"PERF: %.3f MIPS\\n\", (get_itr() / 1000000.0) / (time / 1000.0));"
    , "  hvm_free();"
    , "  return 0;"
    , "}"
    ]
