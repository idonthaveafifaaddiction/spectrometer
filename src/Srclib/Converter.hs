{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

module Srclib.Converter
  ( toSourceUnit
  ) where

import Prelude

import qualified Algebra.Graph.AdjacencyMap as AM
import App.Fossa.Analyze.Project
import Control.Applicative ((<|>))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Set as Set
import DepTypes
import Graphing (Graphing)
import qualified Graphing
import Path (toFilePath)
import Srclib.Types

toSourceUnit :: ProjectResult -> SourceUnit
toSourceUnit ProjectResult{..} =
  SourceUnit
    { sourceUnitName = renderedPath,
      sourceUnitType = projectResultType,
      sourceUnitManifest = renderedPath,
      sourceUnitBuild =
        SourceUnitBuild
          { buildArtifact = "default",
            buildSucceeded = True,
            buildImports = imports,
            buildDependencies = deps
          }
    }
  where
    renderedPath = Text.pack (toFilePath projectResultPath)

    filteredGraph :: Graphing Dependency
    filteredGraph = Graphing.filter (\d -> shouldPublishDep d && isSupportedType d) projectResultGraph

    locatorGraph :: Graphing Locator
    locatorGraph = Graphing.gmap toLocator filteredGraph

    locatorAdjacent :: AM.AdjacencyMap Locator
    locatorAdjacent = Graphing.graphingAdjacent locatorGraph

    deps :: [SourceUnitDependency]
    deps = map (mkSourceUnitDependency locatorAdjacent) (AM.vertexList locatorAdjacent)

    imports :: [Locator]
    imports = Set.toList $ Graphing.graphingDirect locatorGraph

mkSourceUnitDependency :: AM.AdjacencyMap Locator -> Locator -> SourceUnitDependency
mkSourceUnitDependency gr locator = SourceUnitDependency
  { sourceDepLocator = locator
  , sourceDepImports = Set.toList $ AM.postSet locator gr
  }

shouldPublishDep :: Dependency -> Bool
shouldPublishDep Dependency{dependencyEnvironments} =
  null dependencyEnvironments || EnvProduction `elem` dependencyEnvironments || any isOtherEnv dependencyEnvironments

isOtherEnv :: DepEnvironment -> Bool
isOtherEnv (EnvOther _) = True
isOtherEnv _ = False

-- core can't handle subprojects
isSupportedType :: Dependency -> Bool
isSupportedType Dependency{dependencyType} = dependencyType /= SubprojectType && dependencyType /= GooglesourceType

toLocator :: Dependency -> Locator
toLocator dep = Locator
  { locatorFetcher = depTypeToFetcher (dependencyType dep)
  , locatorProject = dependencyName dep
  , locatorRevision = verConstraintToRevision =<< dependencyVersion dep
  }

verConstraintToRevision :: VerConstraint -> Maybe Text
verConstraintToRevision = \case
  CEq ver -> Just ver
  CURI _ -> Nothing -- we can't represent this in a locator
  CCompatible ver -> Just ver
  CAnd a b -> verConstraintToRevision a <|> verConstraintToRevision b
  COr a b -> verConstraintToRevision a <|> verConstraintToRevision b
  CLess ver -> Just ver -- ugh
  CLessOrEq ver -> Just ver -- ugh
  CGreater ver -> Just ver -- ugh
  CGreaterOrEq ver -> Just ver -- ugh
  CNot _ -> Nothing -- we can't represent this in a locator

depTypeToFetcher :: DepType -> Text
depTypeToFetcher = \case
  SubprojectType -> "mvn" -- FIXME. I knew SubprojectType would come back to bite us.
  GooglesourceType -> "git" -- FIXME. Yet another thing that's coming back to bite us
  GitType -> "git"
  GemType -> "gem"
  HexType -> "hex"
  MavenType -> "mvn"
  NodeJSType -> "npm"
  NuGetType -> "nuget"
  PipType -> "pip"
  PodType -> "pod"
  GoType -> "go"
  CarthageType -> "cart"
  CargoType -> "cargo"
  RPMType -> "rpm"
  ComposerType -> "comp"
  HackageType -> "hackage"
