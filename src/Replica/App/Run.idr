module Replica.App.Run

import Control.App
import Control.App.Console

import Data.List
import Data.Maybe
import Data.String

import Language.JSON

import System.Path

import Replica.App.FileSystem
import Replica.App.Replica
import Replica.App.System
import Replica.Command.Run
import Replica.Core.Parse
import Replica.Core.Types
import Replica.Other.String
import Replica.Other.Validation

%default total

data RunContext : Type where

replicaDir : Has [State RunContext RunAction, FileSystem] e => App e String
replicaDir = do
  d <- getCurrentDir
  ctx <- get RunContext
  pure $ d </> ctx.workingDir

runAll :
  SystemIO (SystemError :: e) =>
  Exception TestError e =>
  (String -> TestError) ->
  List String -> App e ()
runAll  _ [] = pure ()
runAll  liftError (x :: xs) =
  handle (system x)
    (const $ runAll liftError xs)
    (\err : SystemError => throw $ liftError x)

expectedVsGiven : Console e => Maybe String -> String -> App e ()
expectedVsGiven old given = do
  case old of
       Nothing => putStrLn "Expected: Nothing Found"
       Just str => do
         putStrLn "Expected:"
         putStrLn str
  putStrLn "Given:"
  putStrLn given

askForNewGolden : FileSystem (FSError :: e) =>
  Has [ State CurrentTest Test
      , State ReplicaDir String
      , Exception TestError
      , Console
      ] e => Maybe String -> String -> App e TestResult
askForNewGolden old given = do
  t <- get CurrentTest
  putStrLn $ "\{t.name}: Golden value mismatch"
  expectedVsGiven old given
  putStrLn $ "Do you want to " ++ maybe "set" (const "replace") old ++ " the golden value? [N/y]"
  if !readAnswer
     then do
       expectedFile <- handle getExpectedFile pure
          (\err : FSError => throw $ FileSystemError
             "Can't resolve expectation file")
       handle (writeFile expectedFile given)
         (const $ pure Success)
         (\err : FSError => throw $ FileSystemError "Cannot write golden value")
     else pure $ maybe (Fail [WrongOutput GoldenIsMissing])
                       (Fail . pure . WrongOutput . flip DifferentOutput given)
                       old
  where
    readAnswer : App e Bool
    readAnswer = do
      answer <- getLine
      pure $ toLower answer `elem` ["y", "yes"]

checkOutput : FileSystem (FSError :: e) =>
  Has [ State CurrentTest Test
      , State ReplicaDir String
      , State RunContext RunAction
      , Exception TestError
      , Console ] e =>
  (mustSucceed : Maybe Bool) -> (status : Int) ->
  (expectedOutput : Maybe String) -> (output : String) ->
  App e TestResult
checkOutput mustSucceed status expectedOutput output
  = do
    ctx <- get RunContext
    case checkExpectation of
         Success => pure $ checkStatus
         Fail err => case checkStatus of
            Fail err2 => pure $ Fail $ err ++ err2
            Success => if ctx.interactive
              then askForNewGolden expectedOutput output
              else pure $ Fail err
    where
      checkStatus : TestResult
      checkStatus = maybe
        Success
        (\s => if (s && status == 0) || (not s && status /= 0)
                  then Success
                  else Fail [WrongStatus s])
        mustSucceed
      checkExpectation : TestResult
      checkExpectation = maybe
        (Fail [WrongOutput GoldenIsMissing])
        (\exp => if exp == output
          then Success
          else Fail [WrongOutput $ DifferentOutput exp output])
        expectedOutput

getExpected : FileSystem (FSError :: e) =>
  Has [ State CurrentTest Test
      , State ReplicaDir String
      , State RunContext RunAction
      , Exception TestError
      , Console
      ] e => String -> App e (Maybe String)
getExpected given = do
  t <- get CurrentTest
  expectedFile <- handle getExpectedFile pure
    (\err : FSError => throw $ FileSystemError
                "Can't resolve exepctation file")
  handle (readFile expectedFile)
    (pure . Just)
    (\err : FSError => case err of
        MissingFile _ => pure Nothing
        err => throw $ FileSystemError "Cannot read expectation")

testCore : SystemIO (SystemError :: e) =>
  FileSystem (FSError :: e) =>
  Has [ State CurrentTest Test
      , State ReplicaDir String
      , State RunContext RunAction
      , Exception TestError
      , Console
      ] e => App e TestResult
testCore = do
  t <- get CurrentTest
  outputFile <- handle getOutputFile pure
            (\err : FSError => throw $ FileSystemError
                "Can't resolve output file")
  exitStatus <- handle (system $ "\{t.command} >> \"\{outputFile}\"")
    (const $ pure 0)
    (\(Err n) => pure n)
  output <- handle (readFile $ outputFile) pure
    (\e : FSError => throw $
          FileSystemError "Can't read output file \{outputFile}")
  expected <- getExpected output
  checkOutput t.mustSucceed exitStatus expected output

performTest : SystemIO (SystemError :: e) =>
  FileSystem (FSError :: e) =>
  Has [ State CurrentTest Test
      , State ReplicaDir String
      , State RunContext RunAction
      , Exception TestError
      , Console
      ] e => App e TestResult
performTest = do
  t <- get CurrentTest
  runAll InitializationFailed t.beforeTest
  res <- testCore
  runAll (WrapUpFailed res) t.afterTest
  pure res

runTest : SystemIO (SystemError :: e) =>
  FileSystem (FSError :: e) =>
  Has [ State RunContext RunAction
      , State ReplicaDir String
      , State CurrentTest Test
      , Exception TestError
      , Console
      ] e => App e TestResult
runTest = do
  ctx <- get RunContext
  t <- get CurrentTest
  let wd = fromMaybe "." t.workingDir
  handle (inDir wd performTest)
    pure
    (\err : FSError => throw $ FileSystemError
      "Error: cannot enter or exit test working directory \{show ctx.workingDir}")

export
Show ReplicaError where
  show (InaccessTestFile x) = "Can't access file \{x}"
  show (InvalidJSON xs) = unlines $ "Can't parse JSON:" ::xs

testOutput :
  Has [ State RunContext RunAction
      , Console
      ] e => String -> Either TestError TestResult -> App e ()
testOutput name x = do
  putStr $ withOffset 2 "\{name}: "
  case x of
       Left y => putStr "⚠️  " >> putStrLn (show y)
       Right Success => putStrLn "✅"
       Right (Fail xs) => putStrLn "❌ \{unwords $ map show xs}"

report : Console e => Stats -> App e ()
report x = do
  putStrLn $ separator 60
  putStrLn "Summary:"
  let nb = countTests x
  if nb == 0
     then putStrLn $ withOffset 2 "No test"
     else putStrLn $ unlines $ catMaybes
    [ guard (x.successes > 0) $>
        withOffset 2 "✅ (Success): \{show x.successes} / \{show nb}"
    , guard (x.failures > 0) $>
        withOffset 2 "❌ (Failure): \{show x.failures} / \{show nb}"
    , guard (x.errors > 0) $>
        withOffset 2 "⚠️  (Errors): \{show x.errors} / \{show nb}"
    ]

export
runReplica : SystemIO (SystemError :: TestError :: e) =>
  SystemIO (SystemError :: e) =>
  FileSystem (FSError :: TestError :: e) =>
  FileSystem (FSError :: e) =>
  Console (TestError :: e) =>
  Has [ State RunContext RunAction
      , Exception ReplicaError
      , Console
      ] e => App e Stats
runReplica = do
  rdir <- handle replicaDir
    pure
    (\err : FSError => throw $ InaccessTestFile "current directory")
  handle (system "mkdir -p \{show rdir}")
    pure
    (\err : SystemError => throw $ InaccessTestFile "\{show rdir}")
  repl <- getReplica RunContext file
  res <- traverse (processTest rdir) repl.tests
  putStrLn $ separator 60
  putStrLn "Test results:"
  traverse_ (uncurry testOutput) res
  let stats = asStats $ map snd res
  report $ stats
  pure stats
  where
    processTest : String -> Test -> App e (String, Either TestError TestResult)
    processTest rdir x = do
      r <- handle
             (new rdir $ new x runTest)
             (pure . MkPair x.name . Right)
             (\err : TestError => pure (x.name, Left err))
      pure r
