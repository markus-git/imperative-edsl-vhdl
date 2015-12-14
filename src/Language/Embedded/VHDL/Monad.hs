{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}

-- used for the Ord/Eq inst. of XDeclaration etc.
{-# LANGUAGE StandaloneDeriving #-}

module Language.Embedded.VHDL.Monad (
    VHDL
  , VHDLT
  , VHDLEnv
  , emptyVHDLEnv
    
    -- ^ run
  , runVHDLT
  , runVHDL
  , execVHDLT
  , execVHDL

    -- ^ pretty
  , prettyVHDL
  , prettyVHDLT

    -- ^ ...
  , freshUnique
  , newSym
  , newLabel

    -- ^ declarations
  , addPort,       addGeneric
  , addGlobal,     addLocal
  , addConcurrent, addSequential
  , addComponent

    -- ^ statements
  , inProcess
  , inConditional
  , inCase

    -- ^ ...
  , entity
  , architecture
  , package

    -- ^ common
  , interfaceConstant, interfaceSignal, interfaceVariable
  , declRecord, declConstant, declSignal, declVariable
                                          
  , portMap
  , assignSignal
  , assignVariable

  , module Language.Embedded.VHDL.Monad.Expression
  ) where

import Language.VHDL (Identifier(..), Mode(..), Expression, Label)
import qualified Language.VHDL as V

import Language.Embedded.VHDL.Expression.Type
import Language.Embedded.VHDL.Monad.Expression

import Control.Arrow          (first, second)
import Control.Applicative
import Control.Monad
import Control.Monad.Identity (Identity)
import Control.Monad.State    (StateT, MonadState, MonadIO)
import qualified Control.Monad.Identity as CMI
import qualified Control.Monad.State    as CMS

import Data.Maybe       (catMaybes)
import Data.Foldable    (toList)
import Data.Functor
import Data.List        (groupBy)
import Data.Set         (Set)
import qualified Data.Set as Set
import Data.Map         (Map)
import qualified Data.Map as Map

import Text.PrettyPrint (Doc, ($+$))
import qualified Text.PrettyPrint as Text

import Prelude hiding (null, not, abs, exp, rem, mod, div, and, or)
import qualified Prelude as P

--------------------------------------------------------------------------------
-- * ..
--------------------------------------------------------------------------------

-- | Code generation state
data VHDLEnv = VHDLEnv
  { _unique        :: !Integer
    -- ..
  , _designs       :: [V.DesignUnit]
    -- ...
  , _context       :: [V.ContextItem]
  , _types         :: Set V.TypeDeclaration
    -- headers
  , _ports         :: [V.InterfaceDeclaration]
  , _generics      :: [V.InterfaceDeclaration]
  , _components    :: Set V.ComponentDeclaration
    -- declarations
  , _global        :: [V.BlockDeclarativeItem]
  , _local         :: [V.BlockDeclarativeItem]
    -- statements
  , _concurrent    :: [V.ConcurrentStatement]
  , _sequential    :: [V.SequentialStatement]
  }

-- | Initial state during code generation
emptyVHDLEnv = VHDLEnv
  { _unique        = 0
  , _designs       = []
  , _context       = []
  , _types         = Set.empty
  , _components    = Set.empty
  , _ports         = []
  , _generics      = []
  , _global        = []
  , _local         = []
  , _concurrent    = []
  , _sequential    = []
  }

--------------------------------------------------------------------------------
-- * 

-- | Type constraints for the VHDL monads
type MonadV m = (Functor m, Applicative m, Monad m, MonadState VHDLEnv m)

-- | VHDL code generation monad
type VHDL = VHDLT Identity

-- | VHDL code genreation monad transformer.
newtype VHDLT m a = VHDLT { unVGenT :: StateT VHDLEnv m a }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadState VHDLEnv
           , MonadIO
           )

-- | Run the VHDL code generation monad transformer.
runVHDLT :: Monad m => VHDLT m a -> VHDLEnv -> m (a, VHDLEnv)
runVHDLT m = CMS.runStateT (unVGenT m)

-- | -- | Executes the VHDL code generation monad transformer, returning only its final state.
execVHDLT :: Monad m => VHDLT m a -> VHDLEnv -> m VHDLEnv
execVHDLT m = CMS.execStateT (unVGenT m)

-- | Run the VHDL code generation monad.
runVHDL :: VHDL a -> VHDLEnv -> (a, VHDLEnv)
runVHDL m = CMI.runIdentity . runVHDLT m

-- | Executes the VHDL code generation monad, returning only its final state.
execVHDL :: VHDL a -> VHDLEnv -> VHDLEnv
execVHDL m = CMI.runIdentity . execVHDLT m

--------------------------------------------------------------------------------
-- ** Generating uniques

-- | Generates a unique integer.
freshUnique :: MonadV m => m Integer
freshUnique =
  do u <- CMS.gets _unique
     CMS.modify (\e -> e { _unique = u + 1 })
     return u

-- | Generates a fresh and unique identifier.
newSym :: MonadV m => m Identifier
newSym = do i <- freshUnique; return (Ident $ 'v' : show i)

-- | Generates a fresh and unique label.
newLabel :: MonadV m => m Label
newLabel = do i <- freshUnique; return (Ident $ 'l' : show i)

--------------------------------------------------------------------------------
-- ** ...

-- | Adds a new library import to the context.
newLibrary :: MonadV m => String -> m ()
newLibrary l = CMS.modify $ \s -> s { _context = item : (_context s) }
  where
    item :: V.ContextItem
    item = V.ContextLibrary (V.LibraryClause (V.LogicalNameList [V.Ident l]))

-- | Adds a new library use clause to the context (with an .all suffix by default).
newImport :: MonadV m => String -> m ()
newImport i = CMS.modify $ \s -> s { _context = item : (_context s) }
  where
    item :: V.ContextItem
    item = V.ContextUse (V.UseClause [V.SelectedName (V.PName (V.NSimple (V.Ident i))) (V.SAll)])

--------------------------------------------------------------------------------
-- ** Header declarations -- ignores port/generic maps for now

-- | Adds a port declaration to the entity.
addPort :: MonadV m => V.InterfaceDeclaration -> m ()
addPort p = CMS.modify $ \s -> s { _ports = p : (_ports s) }

-- | Adds a generic declaration to the entity.
addGeneric :: MonadV m => V.InterfaceDeclaration -> m ()
addGeneric g = CMS.modify $ \s -> s { _generics = g : (_generics s) }

--------------------------------------------------------------------------------
-- ** Type declarations

addType :: MonadV m => V.TypeDeclaration -> m ()
addType t = CMS.modify $ \s -> s { _types = Set.insert t (_types s) }

-- | Adds a component declaration to the architecture.
addComponent :: MonadV m => V.ComponentDeclaration -> m ()
addComponent c = CMS.modify $ \s -> s { _components = Set.insert c (_components s) }

--------------------------------------------------------------------------------
-- ** Item declarations

-- | Adds a global declaration.
addGlobal :: MonadV m => V.BlockDeclarativeItem -> m ()
addGlobal g = CMS.modify $ \s -> s { _global = g : (_global s) }

-- | Adds a local declaration.
addLocal :: MonadV m => V.BlockDeclarativeItem -> m ()
addLocal l = CMS.modify $ \s -> s { _local = l : (_local s) }

--------------------------------------------------------------------------------
-- ** Statement declarations

-- | Adds a concurrent statement.
addConcurrent :: MonadV m => V.ConcurrentStatement -> m ()
addConcurrent con = CMS.modify $ \s -> s { _concurrent = con : (_concurrent s) }

-- | Adds a sequential statement.
addSequential :: MonadV m => V.SequentialStatement -> m ()
addSequential seq = CMS.modify $ \s -> s { _sequential = seq : (_sequential s) }

--------------------------------------------------------------------------------
-- * Concurrent and sequential statements
--------------------------------------------------------------------------------

-- | ... helper ...
contain :: MonadV m => m () -> m [V.SequentialStatement]
contain m = do
  m                                          -- do
  new <- reverse <$> CMS.gets _sequential    -- get
  CMS.modify $ \e -> e { _sequential = [] }  -- reset
  return new                                 -- return

--------------------------------------------------------------------------------
-- ** Process-statements

-- | Runs the given action inside a process.
inProcess :: MonadV m => Label -> [Identifier] -> m a -> m (a, V.ProcessStatement)
inProcess l is m =
  do oldLocals     <- CMS.gets _local
     oldSequential <- CMS.gets _sequential
     CMS.modify $ \e -> e { _local      = []
                          , _sequential = [] }
     result        <- m
     newLocals     <- reverse <$> CMS.gets _local
     newSequential <- reverse <$> CMS.gets _sequential
     CMS.modify $ \e -> e { _local      = oldLocals
                          , _sequential = oldSequential }
     return ( result
            , V.ProcessStatement
                (Just l)                        -- label
                (False)                         -- postponed
                (sensitivity)                   -- sensitivitylist
                (translate $ merge $ newLocals) -- declarativepart
                (newSequential))                -- statementpart
  where
    sensitivity | P.null is = Nothing
                | otherwise = Just $ V.SensitivityList $ fmap V.NSimple is
      
--------------------------------------------------------------------------------
-- ** If-statements

-- | ...
inConditional :: MonadV m => (V.Condition, m ()) -> [(V.Condition, m ())] -> m () -> m (V.IfStatement)
inConditional (c, m) os e =
  do let (cs, ns) = unzip os
     oldSequential <- CMS.gets _sequential
     CMS.modify $ \e -> e { _sequential = [] }
     m'  <- contain m
     ns' <- mapM contain ns
     e'  <- contain e
     CMS.modify $ \e -> e { _sequential = oldSequential }
     return $
       V.IfStatement
         (Nothing)
         (c, m')
         (zip cs ns')
         (maybeList e')
  where
    maybeList :: [V.SequentialStatement] -> Maybe [V.SequentialStatement]
    maybeList xs
      | P.null xs = Nothing
      | otherwise = Just xs

--------------------------------------------------------------------------------
-- ** Case-statements

-- | ...
inCase :: MonadV m => V.Expression -> [(V.Choices, m ())] -> m (V.CaseStatement)
inCase e choices =
  do let (cs, ns) = unzip choices
     oldSequential <- CMS.gets _sequential
     CMS.modify $ \e -> e { _sequential = [] }
     ns' <- mapM contain ns
     CMS.modify $ \e -> e { _sequential = oldSequential }     
     return $
       V.CaseStatement
         (Nothing)
         (e)
         (zipWith V.CaseStatementAlternative cs ns')

--------------------------------------------------------------------------------
-- * Design units
--------------------------------------------------------------------------------

-- | ... design unit with context
addDesign :: MonadV m => V.LibraryUnit -> m ()
addDesign lib =
  do ctxt <- CMS.gets _context
     dsig <- CMS.gets _designs
     let item = V.DesignUnit ctxt lib
     CMS.modify $ \s -> s { _designs = item : dsig
                          , _context = []
                          }

-- | .. design unit ignoring context
addDesign_ :: MonadV m => V.LibraryUnit -> m ()
addDesign_ lib = CMS.modify $ \s -> s { _designs = (V.DesignUnit [] lib) : (_designs s)}

--------------------------------------------------------------------------------
-- ** Architectures

-- | Wraps the given monadic action in an architecture, consuming all global
--   identifiers and concurrent statements it produces. Strings are its entity
--   and architecture names, respectively.
architecture :: MonadV m => String -> String -> m a -> m a
architecture entity name m =
  do oldGlobal     <- CMS.gets _global
     oldConcurrent <- CMS.gets _concurrent
     CMS.modify $ \e -> e { _global     = []
                          , _concurrent = [] }
     result        <- m
     newGlobal     <- CMS.gets _global
     newConcurrent <- CMS.gets _concurrent
     addDesign_ $ V.LibrarySecondary $ V.SecondaryArchitecture $
           V.ArchitectureBody
             (V.Ident name)
             (V.NSimple (V.Ident entity))
             (merge newGlobal)
             (newConcurrent)
     CMS.modify $ \e -> e { _global     = oldGlobal
                          , _concurrent = oldConcurrent }
     return result

--------------------------------------------------------------------------------
-- ** Entities

-- | Declares an entity with the given name by consuming all port-level
--   declaraions and context items produced by running the monadic action.
entity :: MonadV m => String -> m a -> m a
entity name m =
  do oldPorts    <- CMS.gets _ports
     oldGenerics <- CMS.gets _generics
     CMS.modify $ \e -> e { _ports    = []
                          , _generics = [] }
     result      <- m
     newPorts    <- CMS.gets _ports
     newGenerics <- CMS.gets _generics
     addDesign  $ V.LibraryPrimary $ V.PrimaryEntity $
           V.EntityDeclaration
             (V.Ident name)
             (V.EntityHeader
               (V.GenericClause <$> maybeNull newGenerics)
               (V.PortClause    <$> maybeNull newPorts))
             ([])
             (Nothing)
     CMS.modify $ \e -> e { _ports    = oldPorts
                          , _generics = oldGenerics }
     return result
  where
    maybeNull :: [V.InterfaceDeclaration] -> Maybe V.InterfaceList
    maybeNull [] = Nothing
    maybeNull xs = Just $ V.InterfaceList $ merge xs

--------------------------------------------------------------------------------
-- ** Packages

-- | Declares a package with the given name by consuming all type declarations
--   produced by running the monadic action.
--
-- *** package body is always empty for now (until we support VHDL functions).
package :: MonadV m => String -> m a -> m a
package name m =
  do oldTypes <- CMS.gets _types
     CMS.modify $ \e -> e { _types = Set.empty }
     result   <- m
     newTypes <- CMS.gets _types
     addDesign  $ V.LibraryPrimary $ V.PrimaryPackage $
           V.PackageDeclaration
             (V.Ident name)
             (fmap V.PHDIType $ Set.toList newTypes)
     addDesign_ $ V.LibrarySecondary $ V.SecondaryPackage $
           V.PackageBody
             (V.Ident name)
             ([])
     CMS.modify $ \e -> e { _types = oldTypes }
     return result

--------------------------------------------------------------------------------
-- * Pretty
--------------------------------------------------------------------------------

-- | Runs the VHDL monad and pretty prints its resulting VHDL program.
prettyVHDL :: VHDL a -> Doc
prettyVHDL = CMI.runIdentity . prettyVHDLT

-- | Runs the VHDL monad transformer and pretty prints its resulting VHDL program.
prettyVHDLT :: Monad m => VHDLT m a -> m Doc
prettyVHDLT m = prettyVEnv <$> execVHDLT m emptyVHDLEnv

--------------------------------------------------------------------------------

-- | Pretty print a VHDL environment.
prettyVEnv :: VHDLEnv -> Doc
prettyVEnv env = types $+$ desig
  where
    types :: Doc
    types = prettyVTypes (_types env)

    desig :: Doc
    desig = stack (_designs env)

-- | ...
--
-- *** Scan type declarations for necessary imports instead.
-- *** Types are added in an ugly manner.
prettyVTypes :: Set V.TypeDeclaration -> Doc
prettyVTypes set =
    stack . _designs . snd $ runVHDL pack emptyVHDLEnv
  where
    pack :: MonadV m => m ()
    pack = package "types" $ do
      newLibrary "IEEE"
      newImport  "IEEE.STD_LOGIC_1164"
      newImport  "IEEE.STD_LOGIC_UNSIGNED"
      newImport  "IEEE.NUMERIC_STD"
      CMS.modify $ \e -> e { _types = set }

-- | Stacks a number of documents on top of one another
stack :: V.Pretty a => [a] -> Doc
stack = foldr1 ($+$) . fmap V.pp

--------------------------------------------------------------------------------
-- * Common things
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- **  Ports/Generic declarations

interfaceConstant :: Identifier -> Type -> Maybe Expression -> V.InterfaceDeclaration
interfaceConstant i t e = V.InterfaceConstantDeclaration [i] t e

interfaceSignal   :: Identifier -> Mode -> Type -> Maybe Expression -> V.InterfaceDeclaration
interfaceSignal i m t e = V.InterfaceSignalDeclaration [i] (Just m) t False e

interfaceVariable :: Identifier -> Mode -> Type -> Maybe Expression -> V.InterfaceDeclaration
interfaceVariable i m t e = V.InterfaceVariableDeclaration [i] (Just m) t e

--------------------------------------------------------------------------------
-- ** Type/Component Declarations

declRecord :: Identifier -> [(Identifier, Type)] -> V.TypeDeclaration
declRecord name es = V.TDFull
  (V.FullTypeDeclaration
    (name)
    (V.TDComposite (V.CTDRecord (V.RecordTypeDefinition
      (fmap decl es)
      (Just name)))))
  where
    decl (i, t) = V.ElementDeclaration [i] t

-- ... only unconstrained arrays without any index subtype definitions
declArray :: Identifier -> Type -> V.TypeDeclaration
declArray name typ = V.TDFull
  (V.FullTypeDeclaration
    (name)
    (V.TDComposite (V.CTDArray (V.ArrU (V.UnconstrainedArrayDefinition
      ([])
      (typ))))))

--------------------------------------------------------------------------------
-- ** Global/Local Declarations

declConstant :: Identifier -> Type -> Maybe Expression -> V.BlockDeclarativeItem
declConstant i t e = V.BDIConstant $ V.ConstantDeclaration [i] t e

declSignal :: Identifier -> Type -> Maybe Expression -> V.BlockDeclarativeItem
declSignal i t e = V.BDISignal $ V.SignalDeclaration [i] t Nothing e

declVariable :: Identifier -> Type -> Maybe Expression -> V.BlockDeclarativeItem
declVariable i t e = V.BDIShared $ V.VariableDeclaration False [i] t e

--------------------------------------------------------------------------------
-- ** Component instantiation (port mapping)

portMap :: Label -> Identifier -> [V.ActualDesignator] -> V.ConcurrentStatement
portMap l n ns = V.ConComponent $
  V.ComponentInstantiationStatement
    (l)
    (V.IUComponent (V.NSimple n))
    (Nothing)
    (Just $ V.PortMapAspect
      (V.AssociationList $
        fmap (V.AssociationElement Nothing) $
          fmap V.APDesignator ns))

--------------------------------------------------------------------------------
-- ** Assign Signal/Variable

assignSignal :: Identifier -> Expression -> V.SequentialStatement
assignSignal i e = V.SSignalAss $
  V.SignalAssignmentStatement
    (Nothing)
    (V.TargetName (V.NSimple i))
    (Nothing)
    (V.WaveElem [V.WaveEExp e Nothing])

assignVariable :: Identifier -> Expression -> V.SequentialStatement
assignVariable i e = V.SVarAss $
  V.VariableAssignmentStatement
    (Nothing)
    (V.TargetName (V.NSimple i))
    (e)

--------------------------------------------------------------------------------
-- Some helper classes and their instances
--------------------------------------------------------------------------------

class Merge a
  where
    -- group two items if this holds
    group  :: a -> a -> Bool

    -- merge in this way
    reduce :: [a] -> a

    merge :: [a] -> [a]
    merge = fmap reduce . groupBy group


instance Merge V.BlockDeclarativeItem
  where
    group  l r      = setBlockIds l [] == setBlockIds r []
    reduce bs@(b:_) = setBlockIds b $ concatMap getBlockIds bs

instance Merge V.InterfaceDeclaration
  where
    group  l r    = l { V.idecl_identifier_list = [] } == r { V.idecl_identifier_list = [] }
    reduce (x:xs) = x { V.idecl_identifier_list = ids x ++ concatMap ids xs }
      where ids   = V.idecl_identifier_list

--------------------------------------------------------------------------------

setBlockIds :: V.BlockDeclarativeItem -> [Identifier] -> V.BlockDeclarativeItem
setBlockIds (V.BDIConstant c) is = V.BDIConstant $ c { V.const_identifier_list  = is }
setBlockIds (V.BDISignal   s) is = V.BDISignal   $ s { V.signal_identifier_list = is }
setBlockIds (V.BDIShared   v) is = V.BDIShared   $ v { V.var_identifier_list    = is }
setBlockIds (V.BDIFile     f) is = V.BDIFile     $ f { V.fd_identifier_list     = is }
setBlockIds x                 _  = x

getBlockIds :: V.BlockDeclarativeItem -> [Identifier]
getBlockIds (V.BDIConstant c) = V.const_identifier_list c
getBlockIds (V.BDISignal   s) = V.signal_identifier_list s
getBlockIds (V.BDIShared   v) = V.var_identifier_list v
getBlockIds (V.BDIFile     f) = V.fd_identifier_list f

--------------------------------------------------------------------------------
-- I use BlockDeclarativeItem to represent all declarative items, which means we
-- have to translate them over to their correct VHDL kind when generating an AST
--------------------------------------------------------------------------------

class Declarative a
  where
    -- lists are used so we can fail without having to throw errors
    translate :: [V.BlockDeclarativeItem] -> [a]

instance Declarative V.ProcessDeclarativeItem
  where
    translate = catMaybes . fmap tryProcess

-- | Try to transform the declarative item into a process item
tryProcess :: V.BlockDeclarativeItem -> Maybe (V.ProcessDeclarativeItem)
tryProcess (V.BDIConstant c) = Just $ V.PDIConstant c
tryProcess (V.BDIShared   v) = Just $ V.PDIVariable v
tryProcess (V.BDIFile     f) = Just $ V.PDIFile     f
tryProcess _                 = Nothing

--------------------------------------------------------------------------------
-- **  Ord instance for use in sets
--
-- *** These break the Ord rules but seems to be needed for Set.
--     Should be replaced.

deriving instance Ord V.Identifier

instance Ord V.Name
  where
    compare (V.NSimple a) (V.NSimple x) = compare a x
    compare (V.NSelect a) (V.NSelect x) = compare a x
    compare (V.NIndex  a) (V.NIndex  x) = compare a x
    compare (V.NSlice  a) (V.NSlice  x) = compare a x
    compare (V.NAttr   a) (V.NAttr   x) = compare a x

deriving instance Ord V.StringLiteral

deriving instance Ord V.SelectedName

instance Ord V.Suffix
  where
    compare (V.SSimple a) (V.SSimple x) = compare a x
    compare (V.SChar   a) (V.SChar   x) = compare a x
    compare (V.SAll)      (V.SAll)      = EQ
    compare _ _ = error "Ord not supported for operator symbols"

deriving instance Ord V.CharacterLiteral

deriving instance Ord V.IndexedName

deriving instance Ord V.SliceName

deriving instance Ord V.DiscreteRange

instance Ord V.Prefix
  where
    compare (V.PName a) (V.PName x) = compare a x
    compare _ _ = error "Ord not supported for function names"

deriving instance Ord V.AttributeName

deriving instance Ord V.Signature

--------------------------------------------------------------------------------

instance Ord V.TypeDeclaration 
  where
    compare (V.TDFull l)    (V.TDFull r)    = compare (V.ftd_identifier l) (V.ftd_identifier r)
    compare (V.TDPartial l) (V.TDPartial r) = compare l r
    compare (V.TDFull l)    _               = GT
    compare (V.TDPartial l) _               = LT

deriving instance Ord V.IncompleteTypeDeclaration

instance Ord V.ComponentDeclaration
  where
    compare l r = compare (V.comp_identifier l) (V.comp_identifier r)

--------------------------------------------------------------------------------

deriving instance Ord V.SubtypeIndication

deriving instance Ord V.TypeMark

instance Ord V.Constraint
  where
    compare (V.CRange a) (V.CRange b) = compare a b
    compare _ _ = error "Ord not supported for index constraints"

deriving instance Ord V.RangeConstraint

instance Ord V.Range
  where
    compare (V.RSimple a b c) (V.RSimple x y z) =
      case compare a x of
        GT -> GT
        LT -> LT
        EQ -> case compare b y of
          GT -> GT
          LT -> LT
          EQ -> case compare c z of
            GT -> GT
            LT -> LT
            EQ -> EQ
    compare _ _ = error "Ord not supported for attribute ranges"

deriving instance Ord V.Direction

--------------------------------------------------------------------------------

deriving instance Ord V.Expression

deriving instance Ord V.Relation

deriving instance Ord V.ShiftExpression

deriving instance Ord V.SimpleExpression

deriving instance Ord V.Term

deriving instance Ord V.Factor

instance Ord V.Primary
  where
    compare (V.PrimName a) (V.PrimName x) = compare a x

--------------------------------------------------------------------------------

deriving instance Ord V.LogicalOperator

deriving instance Ord V.RelationalOperator

deriving instance Ord V.ShiftOperator

deriving instance Ord V.AddingOperator

deriving instance Ord V.Sign

deriving instance Ord V.MultiplyingOperator

deriving instance Ord V.MiscellaneousOperator

--------------------------------------------------------------------------------
