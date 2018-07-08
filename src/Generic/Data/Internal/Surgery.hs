{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Operate on data types: insert/modify/delete fields and constructors.

module Generic.Data.Internal.Surgery where

import Control.Monad ((<=<))
import Data.Bifunctor (first)
import Data.Kind (Constraint)
import Data.Type.Equality (type (==))
import GHC.Generics
import GHC.TypeNats
import GHC.TypeLits

import Generic.Data.Internal.Compat (Div)
import Generic.Data.Internal.Data
import Generic.Data.Internal.Defun

-- | Generic representation in a list-of-lists ('LoL') shape at the type level
-- (reusing the constructors from "GHC.Generics", as opposed to @generics-sop@
-- for instance).
--
-- This representation makes it easy to modify fields and constructors.
newtype LoL l x = LoL { unLoL :: l x }

-- | Convert the generic representation of a type to a list-of-lists shape.
toLoL :: forall a x. (Generic a, GLinearize (Rep a)) => a -> LoL (Linearize (Rep a)) x
toLoL = LoL . gLinearize . from

-- | Convert a list-of-lists representation to a synthetic generic type.
--
-- The synthesized representation is made of balanced binary trees,
-- corresponding to what GHC would actually generate.
-- That structure assumed by at least one piece of code out there (@aeson@).
toData
  :: forall f l x
  . (GArborify f, Linearize f ~ l, f ~ Arborify l)
  => LoL l x -> Data f x
toData = Data . gArborify . unLoL

-- | The inverse of 'toData'.
fromData :: forall f x. GLinearize f => Data f x -> LoL (Linearize f) x
fromData = LoL . gLinearize . unData

-- | The inverse of 'toLoL'.
fromLoL
  :: forall a l x
  . (Generic a, GArborify (Rep a), Linearize (Rep a) ~ l, Rep a ~ Arborify l)
  => LoL l x -> a
fromLoL = to . gArborify . unLoL

--

type family   Linearize (f :: k -> *) :: k -> *
type instance Linearize (M1 d m f) = M1 d m (LinearizeSum f V1)

type family   LinearizeSum (f :: k -> *) (tl :: k -> *) :: k -> *
type instance LinearizeSum V1 tl = tl
type instance LinearizeSum (f :+: g) tl = LinearizeSum f (LinearizeSum g tl)
type instance LinearizeSum (M1 c m f) tl = M1 c m (LinearizeProduct f U1) :+: tl

type family   LinearizeProduct (f :: k -> *) (tl :: k -> *) :: k -> *
type instance LinearizeProduct U1 tl = tl
type instance LinearizeProduct (f :*: g) tl = LinearizeProduct f (LinearizeProduct g tl)
type instance LinearizeProduct (M1 s m f) tl = M1 s m f :*: tl

class GLinearize f where
  gLinearize :: f x -> Linearize f x

instance GLinearizeSum f V1 => GLinearize (M1 d m f) where
  gLinearize (M1 a) = M1 (gLinearizeSum @_ @V1 (Left a))

class GLinearizeSum f tl where
  gLinearizeSum :: Either (f x) (tl x) -> LinearizeSum f tl x

instance GLinearizeSum V1 tl where
  gLinearizeSum (Left !_) = error "impossible"
  gLinearizeSum (Right c) = c

instance (GLinearizeSum g tl, GLinearizeSum f (LinearizeSum g tl))
  => GLinearizeSum (f :+: g) tl where
  gLinearizeSum (Left (L1 a)) = gLinearizeSum @_ @(LinearizeSum g tl) (Left a)
  gLinearizeSum (Left (R1 b)) = gLinearizeSum @f (Right (gLinearizeSum @g @tl (Left b)))
  gLinearizeSum (Right c) = gLinearizeSum @f (Right (gLinearizeSum @g (Right c)))

instance GLinearizeProduct f U1 => GLinearizeSum (M1 c m f) tl where
  gLinearizeSum (Left (M1 a)) = L1 (M1 (gLinearizeProduct a U1))
  gLinearizeSum (Right c) = R1 c

class GLinearizeProduct f tl where
  gLinearizeProduct :: f x -> tl x -> LinearizeProduct f tl x

instance GLinearizeProduct U1 tl where
  gLinearizeProduct _ = id

instance (GLinearizeProduct g tl, GLinearizeProduct f (LinearizeProduct g tl))
  => GLinearizeProduct (f :*: g) tl where
  gLinearizeProduct (a :*: b) = gLinearizeProduct a . gLinearizeProduct b

instance GLinearizeProduct (M1 s m f) tl where
  gLinearizeProduct = (:*:)

class GArborify f where
  gArborify :: Linearize f x -> f x

instance GArborifySum f V1 => GArborify (M1 d m f) where
  gArborify (M1 a) = case gArborifySum @_ @V1 a of
    Left a' -> M1 a'
    Right !_ -> error "impossible"

class GArborifySum f tl where
  gArborifySum :: LinearizeSum f tl x -> Either (f x) (tl x)

instance GArborifySum V1 tl where
  gArborifySum = Right

instance (GArborifySum g tl, GArborifySum f (LinearizeSum g tl))
  => GArborifySum (f :+: g) tl where
  gArborifySum = first R1 . gArborifySum <=< first L1 . gArborifySum

instance GArborifyProduct f U1 => GArborifySum (M1 c m f) tl where
  gArborifySum (L1 (M1 a)) = Left (M1 (fst (gArborifyProduct @_ @U1 a)))
  gArborifySum (R1 c) = Right c

class GArborifyProduct f tl where
  gArborifyProduct :: LinearizeProduct f tl x -> (f x, tl x)

instance GArborifyProduct U1 tl where
  gArborifyProduct c = (U1, c)

instance (GArborifyProduct g tl, GArborifyProduct f (LinearizeProduct g tl))
  => GArborifyProduct (f :*: g) tl where
  gArborifyProduct abc = (a :*: b, c) where
    (a, bc) = gArborifyProduct abc
    (b,  c) = gArborifyProduct  bc

instance GArborifyProduct (M1 s m f) tl where
  gArborifyProduct (a :*: c) = (a, c)

type family   Arborify (f :: k -> *) :: k -> *
type instance Arborify (M1 d m f) = M1 d m (Eval (ArborifySum (CoArity f) f))

data ArborifySum (n :: Nat) (f :: k -> *) :: TyExp_ (k -> *) -> *
type instance Eval (ArborifySum n V1) = V1
type instance Eval (ArborifySum n (f :+: g)) =
  Eval (If (n == 1)
    (ArborifyProduct (Arity f) f)
    (Arborify' ArborifySum (:+:) n (Div n 2) f g))

data ArborifyProduct (n :: Nat) (f :: k -> *) :: TyExp_ (k -> *) -> *
type instance Eval (ArborifyProduct n (M1 C s f)) = M1 C s (Eval (ArborifyProduct n f))
type instance Eval (ArborifyProduct n U1) = U1
type instance Eval (ArborifyProduct n (f :*: g)) =
  Eval (If (n == 1)
    (Pure f)
    (Arborify' ArborifyProduct (:*:) n (Div n 2) f g))

-- let nDiv2 = Div n 2 in ...
type Arborify' arb op n nDiv2 f g =
   (   Uncurry (Pure2 op)
   <=< Bimap (arb nDiv2) (arb (n-nDiv2))
   <=< SplitAt nDiv2
   ) (op f g)

data SplitAt :: Nat -> (k -> *) -> TyExp_ (k -> *, k -> *) -> *
type instance Eval (SplitAt n (f :+: g)) =
  Eval (If (n == 0)
    (Pure '(V1, f :+: g))
    (Bimap (Pure2 (:+:) f) Pure =<< SplitAt (n-1) g))
type instance Eval (SplitAt n (f :*: g)) =
  Eval (If (n == 0)
    (Pure '(U1, f :*: g))
    (Bimap (Pure2 (:*:) f) Pure =<< SplitAt (n-1) g))

type family   FieldTypeAt (n :: Nat) (f :: k -> *) :: *
type instance FieldTypeAt n (M1 i c f) = FieldTypeAt n f
type instance FieldTypeAt n (f :*: g) = If (n == 0) (FieldTypeOf f) (FieldTypeAt (n-1) g)

type family   FieldTypeOf (f :: k -> *) :: *
type instance FieldTypeOf (M1 s m (K1 i a)) = a

type family   RemoveField (n :: Nat) (f :: k -> *) :: k -> *
type instance RemoveField n (M1 i m f) = M1 i m (RemoveField n f)
type instance RemoveField n (f :*: g) = If (n == 0) g (f :*: RemoveField (n-1) g)

-- | Position of a record field
type family   FieldIndex (field :: Symbol) (f :: k -> *) :: Nat
type instance FieldIndex field (M1 D m f) = FieldIndex field f
type instance FieldIndex field (M1 C m f) = FieldIndex field f
type instance FieldIndex field (M1 S ('MetaSel ('Just field') su ss ds) f :*: g)
  = If (field == field') 0 (1 + FieldIndex field g)

-- | Number of fields of a single constructor
type family   Arity (f :: k -> *) :: Nat
type instance Arity (M1 d m f) = Arity f
type instance Arity (f :+: V1) = Arity f
type instance Arity (f :*: g) = Arity f + Arity g
type instance Arity (K1 i c) = 1
type instance Arity U1 = 0

-- | Number of constructors of a data type
type family   CoArity (f :: k -> *) :: Nat
type instance CoArity (M1 D m f) = CoArity f
type instance CoArity (M1 C m f) = 1
type instance CoArity V1         = 0
type instance CoArity (f :+: g)  = CoArity f + CoArity g

class GRemoveField (n :: Nat) f where
  gRemoveField :: f x -> (FieldTypeAt n f, RemoveField n f x)

instance GRemoveField n f => GRemoveField n (M1 i c f) where
  gRemoveField (M1 a) = M1 <$> gRemoveField @n a

instance (If (n == 0) (() :: Constraint) (GRemoveField (n-1) g), IsBool (n == 0))
  => GRemoveField n (M1 s m (K1 i t) :*: g) where
  gRemoveField (a@(M1 (K1 t)) :*: b) = _If @(n == 0)
    (t, b)
    ((a :*:) <$> gRemoveField @(n-1) b)

class GInsertField (n :: Nat) f where
  gInsertField :: RemoveField n f x -> FieldTypeAt n f -> f x

instance GInsertField n f => GInsertField n (M1 i c f) where
  gInsertField (M1 a) t = M1 (gInsertField @n a t)

instance (If (n == 0) (() :: Constraint) (GInsertField (n-1) g), IsBool (n == 0))
  => GInsertField n (M1 s m (K1 i t) :*: g) where
  gInsertField ab t = _If @(n == 0)
    (M1 (K1 t) :*: ab)
    (let a :*: b = ab in a :*: gInsertField @(n-1) b t)

type family   ConstrAt (n :: Nat) (f :: k -> *) :: k -> *
type instance ConstrAt n (M1 i m f) = ConstrAt n f
type instance ConstrAt n (f :+: g) = If (n == 0) f (ConstrAt (n-1) g)

type family   RemoveConstr (n :: Nat) (f :: k -> *) :: k -> *
type instance RemoveConstr n (M1 i m f) = M1 i m (RemoveConstr n f)
type instance RemoveConstr n (f :+: g) = If (n == 0) g (f :+: RemoveConstr (n-1) g)

class GRemoveConstr (n :: Nat) f where
  gRemoveConstr :: f x -> Either (ConstrAt n f x) (RemoveConstr n f x)

instance GRemoveConstr n f => GRemoveConstr n (M1 i c f) where
  gRemoveConstr (M1 a) = M1 <$> gRemoveConstr @n a

instance (If (n == 0) (() :: Constraint) (GRemoveConstr (n-1) g), IsBool (n == 0))
  => GRemoveConstr n (f :+: g) where
  gRemoveConstr = _If @(n == 0)
    (\case
      L1 a -> Left a
      R1 b -> Right b)
    (\case
      L1 a -> Right (L1 a)
      R1 b -> R1 <$> gRemoveConstr @(n-1) b)

class GInsertConstr (n :: Nat) f where
  gInsertConstr :: Either (ConstrAt n f x) (RemoveConstr n f x) -> f x

instance GInsertConstr n f => GInsertConstr n (M1 i c f) where
  gInsertConstr = M1 . gInsertConstr @n . fmap unM1

instance (If (n == 0) (() :: Constraint) (GInsertConstr (n-1) g), IsBool (n == 0))
  => GInsertConstr n (f :+: g) where
  gInsertConstr = _If @(n == 0)
    (\case
      Left a -> L1 a
      Right b -> R1 b)
    (\case
      Left a -> R1 (gInsertConstr @(n-1) (Left a))
      Right (L1 a) -> L1 a
      Right (R1 b) -> R1 (gInsertConstr @(n-1) (Right b)))
