{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Effect.Exec
  ( Exec (..),
    ExecErr (..),
    exec,
    execThrow,
    Command (..),
    CmdFailure (..),
    AllowErr (..),
    execParser,
    execJson,
    ExecIOC (..),
    runExecIO,
    module System.Exit,
    module X,
  )
where

import Control.Algebra as X
import Control.Applicative (Alternative)
import Control.Effect.Diagnostics
import Control.Effect.Lift (Lift, sendIO)
import Control.Effect.Record
import Control.Effect.Record.TH (deriveRecordable)
import Control.Effect.Replay
import Control.Effect.Replay.TH (deriveReplayable)
import Control.Exception (IOException, try)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as BL
import Data.Kind (Type)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Text.Lazy.Encoding (decodeUtf8)
import Data.Text.Prettyprint.Doc (pretty, viaShow)
import Data.Void (Void)
import GHC.Generics (Generic)
import Path
import Path.IO
import System.Exit (ExitCode (..))
import System.Process.Typed
import Text.Megaparsec (Parsec, runParser)
import Text.Megaparsec.Error (errorBundlePretty)

data Command = Command
  { -- | Command name to use. E.g., "pip", "pip3", "./gradlew".
    cmdName :: Text,
    -- | Arguments for the command
    cmdArgs :: [Text],
    -- | Error (i.e. non-zero exit code) tolerance policy for running commands. This is helpful for commands like @npm@, that nonsensically return non-zero exit codes when a command succeeds
    cmdAllowErr :: AllowErr
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON Command
instance RecordableValue Command

data CmdFailure = CmdFailure
  { cmdFailureName :: Text,
    cmdFailureArgs :: [Text],
    cmdFailureDir :: FilePath,
    cmdFailureExit :: ExitCode,
    cmdFailureStdout :: Stdout,
    cmdFailureStderr :: Stderr
  }
  deriving (Eq, Ord, Show)

instance ToJSON CmdFailure where
  toJSON CmdFailure{..} = object
    [ "cmdFailureName" .= cmdFailureName
    , "cmdFailureArgs" .= cmdFailureArgs
    , "cmdFailureDir" .= cmdFailureDir
    , "cmdFailureExit" .= toRecordedValue cmdFailureExit
    , "cmdFailureStdout" .= toRecordedValue cmdFailureStdout
    , "cmdFailureStderr" .= toRecordedValue cmdFailureStderr
    ]
instance RecordableValue CmdFailure

instance FromJSON CmdFailure where
  parseJSON = withObject "CmdFailure" $ \obj ->
    CmdFailure <$> obj .: "cmdFailureName"
               <*> obj .: "cmdFailureArgs"
               <*> obj .: "cmdFailureDir"
               <*> (obj .: "cmdFailureExit" >>= fromRecordedValue)
               <*> (obj .: "cmdFailureStdout" >>= fromRecordedValue)
               <*> (obj .: "cmdFailureStderr" >>= fromRecordedValue)
instance ReplayableValue CmdFailure

data AllowErr
  = -- | never ignore non-zero exit (return 'ExecErr')
    Never
  | -- | when `stdout` is non-empty, ignore non-zero exit
    NonEmptyStdout
  | -- | always ignore non-zero exit
    Always
  deriving (Eq, Ord, Show, Generic)

instance ToJSON AllowErr
instance RecordableValue AllowErr

type Stdout = BL.ByteString

type Stderr = BL.ByteString

-- TODO: add a "shell command" method; this would help in App.Fossa.VPS.NinjaGraph
data Exec (m :: Type -> Type) k where
  -- | Exec runs a command and returns either:
  -- - stdout when the command succeeds
  -- - a description of the command failure
  Exec :: Path x Dir -> Command -> Exec m (Either CmdFailure Stdout)

$(deriveRecordable ''Exec)
$(deriveReplayable ''Exec)

data ExecErr
  = -- | Command execution failed, usually from a non-zero exit
    CommandFailed CmdFailure
  | -- | Command output couldn't be parsed. command, err
    CommandParseError Command Text
  deriving (Eq, Ord, Show, Generic)

instance ToDiagnostic ExecErr where
  renderDiagnostic = \case
    CommandFailed err -> "Command execution failed: " <> viaShow err
    CommandParseError cmd err -> "Failed to parse command output. command: " <> viaShow cmd <> " . error: " <> pretty err

-- | Execute a command and return its @(exitcode, stdout, stderr)@
exec :: Has Exec sig m => Path x Dir -> Command -> m (Either CmdFailure Stdout)
exec dir cmd = send (Exec dir cmd)

type Parser = Parsec Void Text

-- | Parse the stdout of a command
execParser :: (Has Exec sig m, Has Diagnostics sig m) => Parser a -> Path x Dir -> Command -> m a
execParser parser dir cmd = do
  stdout <- execThrow dir cmd
  case runParser parser "" (TL.toStrict (decodeUtf8 stdout)) of
    Left err -> fatal (CommandParseError cmd (T.pack (errorBundlePretty err)))
    Right a -> pure a

-- | Parse the JSON stdout of a command
execJson :: (FromJSON a, Has Exec sig m, Has Diagnostics sig m) => Path x Dir -> Command -> m a
execJson dir cmd = do
  stdout <- execThrow dir cmd
  case eitherDecode stdout of
    Left err -> fatal (CommandParseError cmd (T.pack (show err)))
    Right a -> pure a

-- | A variant of 'exec' that throws a 'ExecErr' when the command returns a non-zero exit code
execThrow :: (Has Exec sig m, Has Diagnostics sig m) => Path x Dir -> Command -> m BL.ByteString
execThrow dir cmd = do
  result <- exec dir cmd
  case result of
    Left failure -> fatal (CommandFailed failure)
    Right stdout -> pure stdout

runExecIO :: ExecIOC m a -> m a
runExecIO = runExecIOC

newtype ExecIOC m a = ExecIOC {runExecIOC :: m a}
  deriving (Functor, Applicative, Alternative, Monad, MonadIO, MonadFail)

instance Has (Lift IO) sig m => Algebra (Exec :+: sig) (ExecIOC m) where
  alg hdl sig ctx = ExecIOC $ case sig of
    R other -> alg (runExecIOC . hdl) other ctx
    L (Exec dir cmd) -> sendIO $ do
      absolute <- makeAbsolute dir

      let cmdName' = T.unpack $ cmdName cmd
          cmdArgs' = map T.unpack $ cmdArgs cmd

          mkFailure :: ExitCode -> Stdout -> Stderr -> CmdFailure
          mkFailure = CmdFailure (cmdName cmd) (cmdArgs cmd) (fromAbsDir absolute)

          ioExceptionToCmdFailure :: IOException -> CmdFailure
          ioExceptionToCmdFailure = mkFailure (ExitFailure 1) "" . fromString . show

      processResult <- try $ readProcess (setWorkingDir (fromAbsDir absolute) (proc cmdName' cmdArgs'))

      -- apply business logic for considering whether exitcode + stderr constitutes a "failure"
      let mangleResult :: (ExitCode, Stdout, Stderr) -> Either CmdFailure Stdout
          mangleResult (exitcode, stdout, stderr) =
            case (exitcode, cmdAllowErr cmd) of
              (ExitSuccess, _) -> Right stdout
              (_, Never) -> Left $ mkFailure exitcode stdout stderr
              (_, NonEmptyStdout) ->
                if BL.null stdout
                  then Left $ mkFailure exitcode stdout stderr
                  else Right stdout
              (_, Always) -> Right stdout

      let result :: Either CmdFailure Stdout
          result = first ioExceptionToCmdFailure processResult >>= mangleResult

      pure (result <$ ctx)
