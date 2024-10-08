{-# LANGUAGE Rank2Types #-}
module Plugins (
      FrontendPlugin(..), defaultFrontendPlugin, FrontendPluginAction
    , Plugin(..), CommandLineOption, LoadedPlugin(..), lpModuleName
    , defaultPlugin, keepRenamedSource, withPlugins, withPlugins_
    , PluginRecompile(..)
    , purePlugin, impurePlugin, flagRecompile
    ) where


import Control.Monad
import Data.List
import Data.Semigroup qualified
import StubTypes
import TcRnTypes qualified

plugins :: DynFlags -> [LoadedPlugin]
plugins _ = []

type CommandLineOption = String

-- | 'Plugin' is the compiler plugin data type. Try to avoid
-- constructing one of these directly, and just modify some fields of
-- 'defaultPlugin' instead: this is to try and preserve source-code
-- compatibility when we add fields to this.
--
-- Nonetheless, this API is preliminary and highly likely to change in
-- the future.
data Plugin = Plugin {
    installCoreToDos :: CorePlugin
    -- ^ Modify the Core pipeline that will be used for compilation.
    -- This is called as the Core pipeline is built for every module
    -- being compiled, and plugins get the opportunity to modify the
    -- pipeline in a nondeterministic order.
  , tcPlugin :: TcPlugin
    -- ^ An optional typechecker plugin, which may modify the
    -- behaviour of the constraint solver.
  , pluginRecompile :: [CommandLineOption] -> IO PluginRecompile
    -- ^ Specify how the plugin should affect recompilation.
  , parsedResultAction :: [CommandLineOption] -> ModSummary -> HsParsedModule
                            -> Hsc HsParsedModule
    -- ^ Modify the module when it is parsed. This is called by
    -- HscMain when the parsing is successful.
  , renamedResultAction :: [CommandLineOption] -> TcGblEnv
                                -> HsGroup GhcRn -> TcM (TcGblEnv, HsGroup GhcRn)
    -- ^ Modify each group after it is renamed. This is called after each
    -- `HsGroup` has been renamed.
  , typeCheckResultAction :: [CommandLineOption] -> ModSummary -> TcGblEnv
                               -> TcM TcGblEnv
    -- ^ Modify the module when it is type checked. This is called add the
    -- very end of typechecking.
  , spliceRunAction :: [CommandLineOption] -> LHsExpr GhcTc
                         -> TcM (LHsExpr GhcTc)
    -- ^ Modify the TH splice or quasiqoute before it is run.
  , interfaceLoadAction :: forall lcl . [CommandLineOption] -> ModIface
                                          -> IfM lcl ModIface
    -- ^ Modify an interface that have been loaded. This is called by
    -- LoadIface when an interface is successfully loaded. Not applied to
    -- the loading of the plugin interface. Tools that rely on information from
    -- modules other than the currently compiled one should implement this
    -- function.
  }

-- Note [Source plugins]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- The `Plugin` datatype have been extended by fields that allow access to the
-- different inner representations that are generated during the compilation
-- process. These fields are `parsedResultAction`, `renamedResultAction`,
-- `typeCheckResultAction`, `spliceRunAction` and `interfaceLoadAction`.
--
-- The main purpose of these plugins is to help tool developers. They allow
-- development tools to extract the information about the source code of a big
-- Haskell project during the normal build procedure. In this case the plugin
-- acts as the tools access point to the compiler that can be controlled by
-- compiler flags. This is important because the manipulation of compiler flags
-- is supported by most build environment.
--
-- For the full discussion, check the full proposal at:
-- https://ghc.haskell.org/trac/ghc/wiki/ExtendedPluginsProposal


-- | A plugin with its arguments. The result of loading the plugin.
data LoadedPlugin = LoadedPlugin {
    lpPlugin    :: Plugin
    -- ^ the actual callable plugin
  , lpModule    :: ModIface
    -- ^ the module containing the plugin
  , lpArguments :: [CommandLineOption]
    -- ^ command line arguments for the plugin
  }

lpModuleName :: LoadedPlugin -> ModuleName
lpModuleName = moduleName . mi_module . lpModule


data PluginRecompile = ForceRecompile | NoForceRecompile | MaybeRecompile Fingerprint

instance Outputable PluginRecompile where
  ppr ForceRecompile      = text "ForceRecompile"
  ppr NoForceRecompile    = text "NoForceRecompile"
  ppr (MaybeRecompile fp) = text "MaybeRecompile" <+> ppr fp

instance Semigroup PluginRecompile where
  ForceRecompile <> _                     = ForceRecompile
  NoForceRecompile <> r                   = r
  MaybeRecompile fp <> NoForceRecompile   = MaybeRecompile fp
  MaybeRecompile fp <> MaybeRecompile fp' = MaybeRecompile (fingerprintFingerprints [fp, fp'])
  MaybeRecompile _fp <> ForceRecompile    = ForceRecompile

instance Monoid PluginRecompile where
  mempty = NoForceRecompile
  mappend = (Data.Semigroup.<>)

type CorePlugin = [CommandLineOption] -> [CoreToDo] -> CoreM [CoreToDo]
type TcPlugin = [CommandLineOption] -> Maybe TcRnTypes.TcPlugin

purePlugin, impurePlugin, flagRecompile :: [CommandLineOption] -> IO PluginRecompile
purePlugin _args = return NoForceRecompile

impurePlugin _args = return ForceRecompile

flagRecompile =
  return . MaybeRecompile . fingerprintFingerprints . map fingerprintString . sort

-- | Default plugin: does nothing at all! For compatibility reasons
-- you should base all your plugin definitions on this default value.
defaultPlugin :: Plugin
defaultPlugin = Plugin {
        installCoreToDos      = const return
      , tcPlugin              = const Nothing
      , pluginRecompile  = impurePlugin
      , renamedResultAction   = \_ env grp -> return (env, grp)
      , parsedResultAction    = \_ _ -> return
      , typeCheckResultAction = \_ _ -> return
      , spliceRunAction       = \_ -> return
      , interfaceLoadAction   = \_ -> return
    }


-- | A renamer plugin which mades the renamed source available in
-- a typechecker plugin.
keepRenamedSource :: [CommandLineOption] -> TcGblEnv
                  -> HsGroup GhcRn -> TcM (TcGblEnv, HsGroup GhcRn)
keepRenamedSource _ gbl_env group = TcM_ StubM_
{-
  return (gbl_env { tcg_rn_decls = update (tcg_rn_decls gbl_env)
                  , tcg_rn_exports = update_exports (tcg_rn_exports gbl_env) }, group)
  where
    update_exports Nothing = Just []
    update_exports m = m

    update Nothing = Just emptyRnGroup
    update m       = m
-}

type PluginOperation m a = Plugin -> [CommandLineOption] -> a -> m a
type ConstPluginOperation m a = Plugin -> [CommandLineOption] -> a -> m ()

-- | Perform an operation by using all of the plugins in turn.
withPlugins :: Monad m => DynFlags -> PluginOperation m a -> a -> m a
withPlugins df transformation input
  = foldM (\arg (LoadedPlugin p _ opts) -> transformation p opts arg)
          input (plugins df)

-- | Perform a constant operation by using all of the plugins in turn.
withPlugins_ :: Monad m => DynFlags -> ConstPluginOperation m a -> a -> m ()
withPlugins_ df transformation input
  = mapM_ (\(LoadedPlugin p _ opts) -> transformation p opts input)
          (plugins df)

type FrontendPluginAction = [String] -> [(String, Maybe Phase)] -> Ghc ()
data FrontendPlugin = FrontendPlugin {
      frontend :: FrontendPluginAction
    }
defaultFrontendPlugin :: FrontendPlugin
defaultFrontendPlugin = FrontendPlugin { frontend = \_ _ -> return () }
