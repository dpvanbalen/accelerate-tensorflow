{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Module      : Data.Array.Accelerate.TensorFlow.CodeGen.Tensor
-- Copyright   : [2021] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.TensorFlow.CodeGen.Tensor
  where

import Data.Array.Accelerate.TensorFlow.CodeGen.Base

import Data.Array.Accelerate.Array.Data
import Data.Array.Accelerate.Array.Unique
import Data.Array.Accelerate.Representation.Array
import Data.Array.Accelerate.Representation.Shape
import Data.Array.Accelerate.Representation.Type
import Data.Array.Accelerate.Type

import qualified TensorFlow.Core                                    as TF
import qualified TensorFlow.Nodes                                   as TF
import qualified TensorFlow.Output                                  as TF
import qualified TensorFlow.Types                                   as TF
import qualified TensorFlow.Internal.FFI                            as TF

import Control.Applicative                                          ( liftA2 )
import Data.Bits
import Data.Primitive.Vec                                           ( Vec )
import Data.Set                                                     ( Set )
import Foreign.ForeignPtr
import Foreign.Storable
import System.IO.Unsafe
import qualified Data.Set                                           as Set
import qualified Data.Vector.Storable                               as V


type family Tensors t where
  Tensors ()           = ()
  Tensors (Array sh e) = Tensor sh e
  Tensors (a, b)       = (Tensors a, Tensors b)

data Tensor sh e where
  Tensor :: ArrayR (Array sh e)
         -> TensorShape sh
         -> TensorArrayData e
         -> Tensor sh e

type TensorShape sh    = TArrayDataR (TF.Tensor TF.Build) sh
type TensorArrayData e = TArrayDataR (TF.Tensor TF.Build) e

type ScalarTensorArrayData e = TensorArrayData e ~ TF.Tensor TF.Build e

type family TArrayDataR ba a where
  TArrayDataR ba ()     = ()
  TArrayDataR ba (a, b) = (TArrayDataR ba a, TArrayDataR ba b)
  TArrayDataR ba a      = ba (ScalarTensorDataR a)

type HostEquivalentInt  = $( case finiteBitSize (undefined :: Int) of
                               32 -> [t| Int32 |]
                               64 -> [t| Int64 |]
                               _  -> error "expected 32- or 64-bit integer type" )
type HostEquivalentWord = $( case finiteBitSize (undefined :: Word) of
                               32 -> [t| Word32 |]
                               64 -> [t| Word64 |]
                               _  -> error "expected 32- or 64-bit unsigned integer type" )

type family ScalarTensorDataR t where
  ScalarTensorDataR Int       = HostEquivalentInt
  ScalarTensorDataR Int8      = Int8
  ScalarTensorDataR Int16     = Int16
  ScalarTensorDataR Int32     = Int32
  ScalarTensorDataR Int64     = Int64
  ScalarTensorDataR Word      = HostEquivalentWord
  ScalarTensorDataR Word8     = Word8
  ScalarTensorDataR Word16    = Word16
  ScalarTensorDataR Word32    = Word32
  ScalarTensorDataR Word64    = Word64
  ScalarTensorDataR Half      = Half
  ScalarTensorDataR Float     = Float
  ScalarTensorDataR Double    = Double
  ScalarTensorDataR (Vec n t) = ScalarTensorDataR t

instance TF.Nodes (Tensor sh e) where
  getNodes (Tensor (ArrayR _shR _adataR) _sh _adata) = TF.nodesUnion [ shapeNodes _shR _sh, arrayNodes _adataR _adata ]
    where
      shapeNodes :: ShapeR sh -> TensorShape sh -> TF.Build (Set TF.NodeName)
      shapeNodes ShapeRz          ()       = return Set.empty
      shapeNodes (ShapeRsnoc shR) (sh, sz) = TF.nodesUnion [ shapeNodes shR sh, TF.getNodes sz ]

      arrayNodes :: TypeR t -> TensorArrayData t -> TF.Build (Set TF.NodeName)
      arrayNodes TupRunit ()             = return Set.empty
      arrayNodes (TupRpair aR bR) (a, b) = TF.nodesUnion [ arrayNodes aR a, arrayNodes bR b ]
      arrayNodes (TupRsingle aR) a       = scalar aR a
        where
          scalar :: ScalarType t -> TensorArrayData t -> TF.Build (Set TF.NodeName)
          scalar (SingleScalarType t) = single t
          scalar (VectorScalarType _) = unsupported "SIMD-vector types"

          single :: SingleType t -> TensorArrayData t -> TF.Build (Set TF.NodeName)
          single (NumSingleType t) = num t

          num :: NumType t -> TensorArrayData t -> TF.Build (Set TF.NodeName)
          num (IntegralNumType t) = integral t
          num (FloatingNumType t) = floating t

          integral :: IntegralType t -> TensorArrayData t -> TF.Build (Set TF.NodeName)
          integral TypeInt8   = TF.getNodes
          integral TypeInt16  = TF.getNodes
          integral TypeInt32  = TF.getNodes
          integral TypeInt64  = TF.getNodes
          integral TypeWord8  = TF.getNodes
          integral TypeWord16 = TF.getNodes
          integral TypeWord32 = TF.getNodes
          integral TypeWord64 = TF.getNodes
          integral TypeInt    = TF.getNodes
          integral TypeWord   = TF.getNodes

          floating :: FloatingType t -> TensorArrayData t -> TF.Build (Set TF.NodeName)
          floating TypeFloat  = TF.getNodes
          floating TypeDouble = TF.getNodes
          floating TypeHalf   = unsupported "half-precision floating point"

instance TF.Fetchable (Tensor sh e) (Array sh e) where
  getFetch (Tensor (ArrayR _shR _adataR) _sh _adata) =
    liftA2 Array <$> fetchShape _shR _sh <*> fetchArray _adataR _adata
    where
      fetchShape :: ShapeR sh -> TensorShape sh -> TF.Build (TF.Fetch sh)
      fetchShape ShapeRz          ()       = pure (pure ())
      fetchShape (ShapeRsnoc shR) (sh, sz) =
        let
            fetch :: (s ~ ScalarTensorDataR Int) => TF.Tensor TF.Build s -> TF.Build (TF.Fetch Int)
            fetch tensor = do
              tdata <- TF.fetchTensorVector tensor
              return $ fromIntegral . V.head . TF.decodeTensorData <$> tdata
        in
        liftA2 (,) <$> fetchShape shR sh <*> fetch sz

      fetchArray :: TypeR t -> TensorArrayData t -> TF.Build (TF.Fetch (ArrayData t))
      fetchArray TupRunit ()             = pure (pure ())
      fetchArray (TupRpair aR bR) (a, b) = liftA2 (,) <$> fetchArray aR a <*> fetchArray bR b
      fetchArray (TupRsingle aR) a       = scalar aR a
        where
          wrap :: (Storable t, TF.TensorType s, ScalarTensorDataR t ~ s) => TF.Tensor TF.Build s -> TF.Build (TF.Fetch (UniqueArray t))
          wrap tensor = do
            tdata <- TF.fetchTensorVector tensor
            let vector  = TF.tensorDataBytes . TF.unTensorData <$> tdata
                fp      = fst . V.unsafeToForeignPtr0 <$> vector
                ua      = unsafePerformIO . newUniqueArray . castForeignPtr <$> fp
            --
            return ua

          scalar :: ScalarType t -> TensorArrayData t -> TF.Build (TF.Fetch (ArrayData t))
          scalar (SingleScalarType t) = single t
          scalar (VectorScalarType _) = unsupported "SIMD-vector types"

          single :: SingleType t -> TensorArrayData t -> TF.Build (TF.Fetch (ArrayData t))
          single (NumSingleType t) = num t

          num :: NumType t -> TensorArrayData t -> TF.Build (TF.Fetch (ArrayData t))
          num (IntegralNumType t) = integral t
          num (FloatingNumType t) = floating t

          integral :: IntegralType t -> TensorArrayData t -> TF.Build (TF.Fetch (ArrayData t))
          integral TypeInt8   = wrap
          integral TypeInt16  = wrap
          integral TypeInt32  = wrap
          integral TypeInt64  = wrap
          integral TypeWord8  = wrap
          integral TypeWord16 = wrap
          integral TypeWord32 = wrap
          integral TypeWord64 = wrap
          integral TypeInt    = wrap
          integral TypeWord   = wrap

          floating :: FloatingType t -> TensorArrayData t -> TF.Build (TF.Fetch (ArrayData t))
          floating TypeFloat  = wrap
          floating TypeDouble = wrap
          floating TypeHalf   = unsupported "half-precision floating point"

instance TF.Nodes () where
  getNodes () = return Set.empty

instance TF.Fetchable () () where
  getFetch () = pure (pure ())

