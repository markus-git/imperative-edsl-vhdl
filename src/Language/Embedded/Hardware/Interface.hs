{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Language.Embedded.VHDL.Interface where

import Language.VHDL (Expression, Identifier(..))
import qualified Language.VHDL as V

import Language.Embedded.VHDL.Monad (VHDL)
import Language.Embedded.VHDL.Monad.Type (Type)
import qualified Language.Embedded.VHDL.Monad as M

import Control.Applicative ((<$>))
import Data.Constraint
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- *
--------------------------------------------------------------------------------

type family PredicateExp (exp :: * -> *) :: * -> Constraint

-- | General interface for evaluating expressions
class EvaluateExp exp
  where
    -- | Literal expressions
    litE  :: PredicateExp exp a => a -> exp a

    -- | Evaluation of (closed) expressions
    evalE :: PredicateExp exp a => exp a -> a


-- | General interface for compiling expressions
class CompileExp exp
  where
    -- | Variable expressions
    varE  :: PredicateExp exp a => Integer -> exp a

    -- | Compilation of type kind
    compT :: PredicateExp exp a => exp a -> VHDL Type

    -- | Compilation of expressions
    compE :: PredicateExp exp a => exp a -> VHDL Expression

--------------------------------------------------------------------------------