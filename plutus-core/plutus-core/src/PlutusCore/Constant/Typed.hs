-- | This module assigns types to built-ins.
-- See the @plutus/plutus-core/docs/Constant application.md@
-- article for how this emerged.

{-# LANGUAGE BlockArguments           #-}
{-# LANGUAGE ConstraintKinds          #-}
{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE DefaultSignatures        #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE LambdaCase               #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE PolyKinds                #-}
{-# LANGUAGE QuantifiedConstraints    #-}
{-# LANGUAGE RankNTypes               #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications         #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE TypeOperators            #-}
{-# LANGUAGE UndecidableInstances     #-}
{-# LANGUAGE UndecidableSuperClasses  #-}

{-# LANGUAGE StrictData               #-}

module PlutusCore.Constant.Typed
    ( TypeScheme (..)
    , argOf
    , FoldArgs
    , FoldArgsEx
    , TyNameRep (..)
    , TyVarRep
    , TyAppRep
    , TyForallRep
    , Opaque (..)
    , throwNotAConstant
    , AsConstant (..)
    , FromConstant (..)
    , HasConstant
    , HasConstantIn
    , Hole
    , RepHole
    , TypeHole
    , KnownBuiltinTypeAst
    , KnownTypeAst (..)
    , Merge
    , ListToBinds
    , KnownBuiltinTypeIn
    , KnownBuiltinType
    , readKnownConstant
    , KnownTypeIn (..)
    , KnownType
    , TestTypesFromTheUniverseAreAllKnown
    , readKnownSelf
    , makeKnownOrFail
    , SomeConstant (..)
    ) where

import PlutusPrelude

import PlutusCore.Constant.Dynamic.Emit
import PlutusCore.Constant.Kinded
import PlutusCore.Core
import PlutusCore.Evaluation.Machine.ExBudget
import PlutusCore.Evaluation.Machine.ExMemory
import PlutusCore.Evaluation.Machine.Exception
import PlutusCore.Evaluation.Result
import PlutusCore.MkPlc hiding (error)
import PlutusCore.Name

import Control.Monad.Except
import Data.Kind qualified as GHC (Constraint, Type)
import Data.Proxy
import Data.Some.GADT qualified as GADT
import Data.String
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Exts (inline, oneShot)
import GHC.Ix
import GHC.TypeLits
import Universe

infixr 9 `TypeSchemeArrow`

-- | Type schemes of primitive operations.
-- @as@ is a list of types of arguments, @r@ is the resulting type.
-- E.g. @Text -> Bool -> Integer@ is encoded as @TypeScheme term [Text, Bool] Integer@.
data TypeScheme term (args :: [GHC.Type]) res where
    TypeSchemeResult
        :: KnownType term res
        => TypeScheme term '[] res
    TypeSchemeArrow
        :: KnownType term arg
        => TypeScheme term args res -> TypeScheme term (arg ': args) res
    TypeSchemeAll
        :: (KnownSymbol text, KnownNat uniq, KnownKind kind)
           -- Here we require the user to manually provide the unique of a type variable.
           -- That's nothing but silly, but I do not see what else we can do with the current design.
        => Proxy '(text, uniq, kind)
        -> TypeScheme term args res
        -> TypeScheme term args res

argOf :: TypeScheme term (arg ': args) res -> Proxy arg
argOf _ = Proxy

-- | Turn a list of Haskell types @args@ into a functional type ending in @res@.
--
-- >>> :set -XDataKinds
-- >>> :kind! FoldArgs [Text, Bool] Integer
-- FoldArgs [Text, Bool] Integer :: *
-- = Text -> Bool -> Integer
type family FoldArgs args res where
    FoldArgs '[]           res = res
    FoldArgs (arg ': args) res = arg -> FoldArgs args res

-- | Calculates the parameters of the costing function for a builtin.
type family FoldArgsEx args where
    FoldArgsEx '[]           = ExBudget
    FoldArgsEx (arg ': args) = ExMemory -> FoldArgsEx args

{- Note [Motivation for polymorphic built-in functions]
We need to support polymorphism for built-in functions for these reasons:

1. @ifThenElse@ for 'Bool' (being a built-in type rather than a Scott-encoded one) has to be
   polymorphic as its type signature is

       ifThenElse : all a. Bool -> a -> a -> a

   Previously we had 'Bool' as a Scott-encoded type, but this required plenty of supporting machinery,
   because unlifting (aka Scott-decoding) a PLC 'Bool' into a Haskell 'Bool' is quite a non-trivial
   thing, see https://github.com/input-output-hk/plutus/blob/e222466e6d46bbca9f76243bb496b3c88ed02ca1/language-plutus-core/src/PlutusCore/Constant/Typed.hs#L165-L252

   Now that we got rid of all this complexity we have to pay for that by supporting polymorphic
   built-in functions (but we added that support long ago anyway, 'cause it was easy to do).

2. we may want to add efficient polymorphic built-in types like @IntMap@ or @Vector@ and most functions
   defined over them are polymorphic as well
-}

{- Note [Implementation of polymorphic built-in functions]
Encoding polymorphism in an AST in an intrinsically-typed manner is not a pleasant thing to do in Haskell.
It's not impossible, see "Embedding F", Sam Lindley: http://homepages.inf.ed.ac.uk/slindley/papers/embedding-f.pdf
But we'd rather avoid such heavy techniques.

Fortunately, there is a simple trick: we have parametricity in Haskell, so a function that is
polymorphic in its argument can't inspect that argument in any way and so we never actually need to
convert such an argument from PLC to Haskell just to convert it back later without ever inspecting
the value. Instead we can keep the argument intact and apply the Haskell function directly to
the PLC AST representing some value.

E.g. Having a built-in function with the following signature:
(TODO: we can't have that, figure out a way to make this example actually work while being as
clear as it currently is)

    reverse : all a. [a] -> [a]

that maps to Haskell's

    reverse :: forall a. [a] -> [a]

evaluation of

    PLC.reverse {bool} (cons true (cons false nil))

proceeds as follows:

      PLC.reverse {bool} (cons true (cons false nil))
    ~ makeKnown (Haskell.reverse (readKnown (cons true (cons false nil))))
    ~ makeKnown (Haskell.reverse [Opaque true, Opaque false])
    ~ makeKnown [Opaque false, Opaque true]
    ~ EvaluationSuccess (cons false (cons true nil))

Note how we use the 'Opaque' wrapper in order to unlift a PLC term as an opaque Haskell value
using 'readKnown' and then lift the term back using 'makeKnown' without ever inspecting the term.

An opaque PLC @term@ whose type is a PLC type variable `a_0` has the following type on the Haskell
side:

    Opaque term (TyVarRep ('TyNameRep "a" 0))

where that last argument is a direct counterpart of the term-level

    TyVar () (TyName (Name "a" 0))

@Opaque term rep@ can be used for passing any @term@ through the builtin application machinery,
not just one whose type is a bound variable. For example, you can define a new data type

    data NatRep

provide a 'KnownTypeAst' instance for it (mapping a @Proxy NatRep@ to the actual type of natural
numbers in PLC) and define a (rather pointless) builtin like @idNat : nat -> nat@.

It's also possible to bind a type variable of a higher-kind, say, @f :: * -> *@ and make a builtin
with the following signature:

    idFInteger : all (f :: * -> *). f integer -> f integer

where the type application is handled with 'TyAppRep'. Note that the latter is defined as a
@data family@:

    data family TyAppRep (fun :: dom -> cod) (arg :: dom) :: cod

We do that because a @data family@ can return a poly-kinded argument, which allows us to get an
intrinsically-kinded representation of PLC types. For example, an opaque @term@ whose type is an
application of a type variable @f@ to a type variable @a@ is represented like this:

    Opaque term (TyAppRep (TyVarRep ('TyNameRep "f" 0)) (TyVarRep ('TyNameRep "a" 1 :: TyNameRep *)))

Note the @TyNameRep *@ kind annotation. It tells us three things:

1. a type-level name has a kind associated with it. The reason for that is that we use names in
binders (for example, in the universal quantifier) and as variables and kinds are important in
both these cases due to us having an intrinsically-kinded representation of types, so it's
convenient to annotate type-level names with kinds. Another reason is that we do not attempt to do
any kind of static analysis on reflected type variables and associating kinds with them allows us
to catch errors like "two variables with equal names and uniques, but different kinds" earlier
2. the kind is not stored as an argument to the @TyNameRep@ constructor. Instead it's stored as
an index of the data type. The point of this is that if we stored the kind as an argument, we'd
have to provide it manually, but since the representation is intrinsically-kinded there's no point
in doing so as GHC can infer all the kinds itself
3. ... apart from cases where they're inherently ambiguous, like in the case above. If we don't
specify the kind of the @a_1@ type variable, then there's no way GHC could infer it as the variable
is passed as an argument to another variable with an unspecified kind (@f_0@)
4. finally, an opaque term can only be of a type of kind @*@. You can't construct a term whose type
is of some other kind. That's why we don't need to annotate the @f_0@ type variable: the domain is
inferred from the kind of the argument (where it's explicitly specified via @TyNameRep *@) and the
codomain is inferred from the fact that the whole type is passed to 'Opaque' and so it has to be
of kind @*@

It would be nice if we didn't need to define that @*Rep@ stuff at the type level just to demote it
to the term level via a type class, but this hasn't been investigated yet. A plausible way would be
to ditch 'KnownTypeAst' (but keep 'KnownType') and provide PLC types manually. But that doesn't seem
to give rise to a terribly nice API. And we'd lose all the static guarantees, which is not a big
deal, but losing the automatic inference of type schemes would suck, given that it's quite handy.

Representing contructors as poly-kinded data families and handling those with open type families
and/or type classes is a way of solving the expression problem for indexed data types at the type
level, if you are into these things.
-}

{- Note [Pattern matching on built-in types]
At the moment we really only support direct pattern matching on enumeration types: 'Void', 'Unit',
'Bool' etc. This is because the denotation of a builtin cannot construct general terms (as opposed
to constants), only juggle the ones that were provided as arguments without changing them.
So e.g. if we wanted to add the following data type:

    newtype AnInt = AnInt Int

as a built-in type, we wouldn't be able to add the following function as its pattern matcher:

    matchAnInt :: AnInt -> (Int -> r) -> r
    matchAnInt (AnInt i) f = f i

because currently we cannot express the @f i@ part using the builtins machinery as that would
require applying an arbitrary Plutus Core function in the denotation of a builtin, which would
allow us to return arbitrary terms from the builtin application machinery, which is something
that we originally had, but decided to abandon due to performance concerns.

But it's still possible to have @AnInt@ as a built-in type, it's just that instead of trying to
make its pattern matcher into a builtin we can have the following builtin:

    anIntToInt :: AnInt -> Int
    anIntToInt (AnInt i) = i

which fits perfectly well into the builtins machinery.

Although that becomes annoying for more complex data types. For tuples we need to provide two
projection functions ('fst' and 'snd') instead of a single pattern matcher, which is not too
bad, but to get pattern matching on lists we need three built-in functions: @null@, @head@ and
@tail@ and to require `Bool` to be in the universe to be able to define a PLC equivalent of

    matchList :: [a] -> r -> (a -> [a] -> r) -> r
    matchList xs z f = if null xs then z else f (head xs) (tail xs)

If a constructor stores more than one value, the corresponding projection function packs them
into a (possibly nested) pair, for example for

    data Data
        = Constr Integer [Data]
        | <...>

we have (pseudocode):

    unConstrData (Constr i ds) = (i, ds)

In order to get pattern matching over 'Data' we need a projection function per constructor as well
as with lists, but writing (where the @Data@ suffix indicates that a function is a builtin that
somehow corresponds to a constructor of 'Data')

    if isConstrData d
        then uncurry fConstr $ unConstrData d
        else if isMapData d
            then fMap $ unMapData d
            else if isListData d
                then fList $ unListData d
                else <...>

is tedious and inefficient and so instead we have a single @chooseData@ builtin that matches on
its @Data@ argument and chooses the appropriate branch (type instantiations and strictness concerns
are omitted for clarity):

     chooseData
        (uncurry fConstr $ unConstrData d)
        (fMap $ unMapData d)
        (fList $ unListData d)
        <...>
        d

which, for example, evaluates to @fMap es@ when @d@ is @Map es@

On the bright side, this encoding of pattern matchers does work, so maybe it's indeed worth to
prioritize performance over convenience, especially given the fact that performance is of a concern
to every single end user while the inconvenience is only a concern for the compiler writers and
we don't add complex built-in types too often.
-}

{- Note [Representable built-in functions over polymorphic built-in types]
In Note [Pattern matching on built-in types] we talked about how general higher-order polymorphic
built-in functions are troubling, but polymorphic built-in functions can be troubling even in
the first-order case. In a Plutus program we always pair constants of built-in types with their
tags from the universe, which means that in order to produce a constant embedded into a program
we need the tag of the type of that constant. We can't get that tag from a Plutus type -- those
are gone at runtime, so the only place we can get a type tag from during evaluation is some already
existing constant. I.e. the following built-in function is representable:

    tail : all a. [a] -> [a]

because for constructing the result we need a type tag for @[a]@, but we have a value of that type
as an argument and so we can extract the type tag from it. Same applies to

    swap : all a b. (a, b) -> (b, a)

since 'SomeConstantOf' always contains a type tag for each type that a polymorphic built-in type is
instantiated with and so constructing a type tag for @(b, a)@ given type tags for @a@ and @b@ is
unproblematic.

And so neither

    cons : all a. a -> [a] -> [a]

is troubling (even though that ones requires checking at runtime that the element to be prepended
is of the same type as the type of the elements of the list as it's impossible to enforce this kind
of type safety in Haskell over possibly untyped PLC).

However consider the following imaginary builtin:

    nil : all a. [a]

we can't represent it for two reasons:

1. we don't have any argument providing us a type tag for @a@ and hence we can't construct a type
   tag for @[a]@
2. it would be a very unsound builtin to have. We can only instantiate built-in types with other
   built-in types and so allowing @nil {some_non_built_in_type}@ would be a lie that couldn't reduce
   to anything since it's not even possible to represent a built-in list with non-built-in elements
   (even if there's zero of them)

"Wait, but wouldn't @cons {some_non_built_in_type}@ be a lie as well?" -- No! Since @cons@ does not
just construct a list filled with elements of a non-built-in type but also expects one as an
argument and providing such an argument is impossible, 'cause it's pretty much the same thing as
populating 'Void' -- both values are equally unrepresentable. And so @cons {some_non_built_in_type}@
is a way to say @absurd@, which is perfectly fine to have.

Finally,

    comma :: all a b. a -> b -> (a, b)

is representable (because we can require arguments to be constants carrying universes with them,
which we can use to construct the resulting universe), but is still a lie, because instantiating
that builtin with non-built-in types is possible and so the PLC type checker won't throw on such
an instantiation, which will become 'EvalutionFailure' at runtime the moment unlifting of a
non-constant is attempted when a constant is expected.

So could we still get @nil@ or a safe version of @comma@ somehow? Well, we could have this
weirdness:

    nilOfTypeOf : all a. [a] -> [a]

i.e. ask for an already existing list, but ignore the actual list and only use the type tag.

But since we're ignoring the actual list, can't we just not pass it in the first place? And instead
pass around our good old friends, singletons. We should be able to do that, but it hasn't been
investigated. Perhaps something along the lines of adding the following constructor to 'DefaultUni':

    DefaultUniProtoSing :: DefaultUni (Esc (Proxy @GHC.Type))

and then defining

    nil : all a. sing a -> [a]

and then the Plutus Tx compiler can provide a type class or something for constructing singletons
for built-in types.
-}

-- | Representation of a type variable: its name and unique and an implicit kind.
data TyNameRep (kind :: GHC.Type) = TyNameRep Symbol Nat

-- | Representation of an intrinsically-kinded type variable: a name.
data family TyVarRep (name :: TyNameRep kind) :: kind

-- | Representation of an intrinsically-kinded type application: a function and an argument.
data family TyAppRep (fun :: dom -> cod) (arg :: dom) :: cod

-- | Representation of of an intrinsically-kinded universal quantifier: a bound name and a body.
data family TyForallRep (name :: TyNameRep kind) (a :: GHC.Type) :: GHC.Type

-- | Throw an 'UnliftingError' saying that the received argument is not a constant.
throwNotAConstant
    :: (MonadError (ErrorWithCause err cause) m, AsUnliftingError err)
    => Maybe cause -> m r
throwNotAConstant = throwingWithCause _UnliftingError "Not a constant"

class AsConstant term where
    -- | Unlift from the 'Constant' constructor throwing an 'UnliftingError' if the provided @term@
    -- is not a 'Constant'.
    asConstant
        :: (MonadError (ErrorWithCause err cause) m, AsUnliftingError err)
        => Maybe cause -> term -> m (Some (ValueOf (UniOf term)))

class FromConstant term where
    -- | Wrap a Haskell value as a @term@.
    fromConstant :: Some (ValueOf (UniOf term)) -> term

type instance UniOf (Opaque term rep) = UniOf term

-- See Note [Motivation for polymorphic built-in functions].
-- See Note [Implementation of polymorphic built-in functions].
-- See Note [Pattern matching on built-in types].
-- | The denotation of a term whose PLC type is encoded in @rep@ (for example a type variable or
-- an application of a type variable). I.e. the denotation of such a term is the term itself.
-- This is because we have parametricity in Haskell, so we can't inspect a value whose
-- type is, say, a bound variable, so we never need to convert such a term from Plutus Core to
-- Haskell and back and instead can keep it intact.
newtype Opaque term (rep :: GHC.Type) = Opaque
    { unOpaque :: term
    } deriving newtype (Pretty, AsConstant, FromConstant)

instance AsConstant (Term TyName Name uni fun ann) where
    asConstant _        (Constant _ val) = pure val
    asConstant mayCause _                = throwNotAConstant mayCause

instance FromConstant (Term tyname name uni fun ()) where
    fromConstant = Constant ()

-- | Ensures that @term@ has a 'Constant'-like constructor to lift values to and unlift values from.
--
-- 'AsConstant' and 'FromConstant' are separate, because we need only one instance of 'AsConstant'
-- per 'Term'-like type and 'FromConstant' requires as many instances as there are different kinds
-- of annotations (we're mostly interested in 'ExMemory' and @()@). Originally we had a single type
-- class but it proved to be less efficient than having two of them.
type HasConstant term = (AsConstant term, FromConstant term)

-- | Ensures that @term@ has a 'Constant'-like constructor to lift values to and unlift values from
-- and connects @term@ and its @uni@.
type HasConstantIn uni term = (UniOf term ~ uni, HasConstant term)

{- Note [Rep vs Type context]
Say you define an @Id@ built-in function and specify its Haskell type signature:

    id :: forall a. a -> a

This gets picked up by the 'TypeScheme' inference machinery, which detects @a@ and instantiates it
to @Opaque term Var0@ where @Var0@ is some concrete type (the exact details don't matter here)
representing a Plutus type variable of kind @*@ with the @0@ unique, so @id@ elaborates to

    id :: Opaque term Var0 -> Opaque term Var0

But consider also the case where you want to define @id@ only over lists. The signature of the
built-in function then is

    idList :: forall a. Opaque term [a] -> Opaque term [a]

Now the 'Opaque' is explicit and the 'TypeScheme' inference machinery needs to go under it in order
to instantiate @a@. Which now does not get instantiated to an 'Opaque' as before, since we're
already inside an 'Opaque' and can just use @Var0@ directly. So @idList@ elaborates to

    idList :: Opaque term [Var0] -> Opaque term [Var0]

Now let's make up some syntax for annotating contexts so that it's clear what's going on:

    idList @Type |
        :: (@Type | Opaque term (@Rep | [Var0]))
        -> (@Type | Opaque term (@Rep | [Var0]))

'@ann |' annotates everything to the right of it. The whole thing then reads as

1. a builtin is always defined in the Type context
2. @->@ preserves the Type context, i.e. it accepts it and passes it down to the domain and codomain
3. @Opaque term@ switches the context from Type to Rep, i.e. it accepts the Type context, but
creates the Rep context for its argument that represents a Plutus type

So why the distinction?

The difference between the Rep and the Type contexts that we've seen so far is that in the Rep
context we don't need any @Opaque@, but this is a very superficial reason to keep the distinction
between contexts, since everything that is legal in the Type context is legal in the Rep context
as well. For example we could've elaborated @idList@ into a bit more verbose

    idList :: Opaque term [Opaque term Var0] -> Opaque term [Opaque term Var0]

and the world wouldn't end because of that, everything would work correctly.

The opposite however is not true: certain types that are legal in the Rep context are not legal in
the Type one and this is the reason why the distinction exists. The simplest example is

    id :: Var0 -> Var0

@Var0@ represents a Plutus type variable and it's a data family with no inhabitants, so it does not
make sense to try to unlift a value of that type.

Now let's say we added a @term@ argument to @Var0@ and said that when @Var0 term@ is a @GHC.Type@,
it has a @term@ inside, just like 'Opaque'. Then we would be able to unlift it, but we also have
things like @TyAppRep@, @TyForallRep@ and that set is open, any Plutus type can be represented
using such combinators and we can even name particular types, e.g. we could have @PlcListRep@,
so we'd have to special-case @GHC.Type@ for each of them and it would be a huge mess.

So instead of mixing up types whose values are actually unliftable with types that are only used
for type checking, we keep the distinction explicit.

The barrier between Haskell and Plutus is the barrier between the Type and the Rep contexts and
that barrier must always be some explicit type constructor that switches the context from Type to
Rep. We've only considered 'Opaque' as an example of such type constructor, but we also have
'SomeConstant' as another example.

Some type constructors turn any context into the Type one, for example 'EvaluationResult' and
'Emitter', although they are useless inside the Rep context, given that it's only for type checking
Plutus and they don't exist in the type language of Plutus.

These @*Rep@ data families like 'TyVarRep', 'TyAppRep' etc all require the Rep context and preserve
it, since they're only for representing Plutus types for type checking purposes.

We call a thing in a Rep or 'Type' context a 'RepHole' or 'TypeHole' respectively. The reason for
the name is that the inference machinery looks at the thing and tries to instantiate it, like fill
a hole.

We could also have a third type of hole/context, Name, because binders bind names rather than
variables and so it makes sense to infer names sometimes, like for 'TyForallRep' for example.
We don't do that currently, because we don't have such builtins anyway.

And there could be even fancier kinds of holes like "infer anything" for cases where the hole
is determined by some other part of the signature. We don't have that either, for the same reason.

For the user defining a builtin this all is pretty much invisible.
-}

-- See Note [Rep vs Type context].
-- | The kind of holes.
data Hole

-- See Note [Rep vs Type context].
-- | A hole in the Rep context.
type RepHole :: forall a hole. a -> hole
data family RepHole x

-- See Note [Rep vs Type context].
-- | A hole in the Type context.
type TypeHole :: forall hole. GHC.Type -> hole
data family TypeHole a

-- | For annotating an uninstantiated built-in type, so that it gets handled by the right instance
-- or type family.
type BuiltinHead :: forall k. k -> k
data family BuiltinHead f

-- | Take an iterated application of a built-in type and elaborate every function application
-- inside of it to 'TypeAppRep', plus annotate the head with 'BuiltinHead'.
-- The idea is that we don't need to process built-in types manually if we simply add some
-- annotations for instance resolution to look for. Think what we'd have to do manually for, say,
-- 'ToHoles': traverse the spine of the application and collect all the holes into a list, which is
-- troubling, because type applications are left-nested and lists are right-nested, so we'd have to
-- use accumulators or an explicit 'Reverse' type family. And then we also have 'KnownTypeAst' and
-- 'ToBinds', so handling built-in types in a special way for each of those would be a hassle,
-- especially given the fact that type-level Haskell is not exactly good at computing things.
-- With the 'ElaborateBuiltin' approach we get 'KnownTypeAst', 'ToHoles' and 'ToBinds' for free.
type ElaborateBuiltin :: forall k. k -> k
type family ElaborateBuiltin a where
    ElaborateBuiltin (f x) = ElaborateBuiltin f `TyAppRep` x
    ElaborateBuiltin f     = BuiltinHead f

-- | A constraint for \"@a@ is a 'KnownTypeAst' by means of being included in @uni@\".
type KnownBuiltinTypeAst uni a = KnownTypeAst uni (ElaborateBuiltin a)

type KnownTypeAst :: forall k. (GHC.Type -> GHC.Type) -> k -> GHC.Constraint
class KnownTypeAst uni a where
    -- | Return every part of the type that can be a to-be-instantiated type variable.
    -- For example, in @Integer@ there's no such types and in @(a, b)@ it's the two arguments
    -- (@a@ and @b@) and the same applies to @a -> b@ (to mention a type that is not built-in).
    type ToHoles a :: [Hole]
    type ToHoles a = ToHoles (ElaborateBuiltin a)

    -- | Collect all unique variables (a variable consists of a textual name, a unique and a kind)
    -- in an @a@.
    type ToBinds a :: [GADT.Some TyNameRep]
    type ToBinds a = ToBinds (ElaborateBuiltin a)

    -- | The type representing @a@ used on the PLC side.
    toTypeAst :: proxy a -> Type TyName uni ()
    default toTypeAst :: KnownBuiltinTypeAst uni a => proxy a -> Type TyName uni ()
    toTypeAst _ = toTypeAst $ Proxy @(ElaborateBuiltin a)
    {-# INLINE toTypeAst #-}

instance (KnownTypeAst uni a, KnownTypeAst uni b) => KnownTypeAst uni (a -> b) where
    type ToHoles (a -> b) = '[TypeHole a, TypeHole b]
    type ToBinds (a -> b) = Merge (ToBinds a) (ToBinds b)

    toTypeAst _ = TyFun () (toTypeAst $ Proxy @a) (toTypeAst $ Proxy @b)
    {-# INLINE toTypeAst #-}

instance uni `Contains` f => KnownTypeAst uni (BuiltinHead f) where
    type ToHoles (BuiltinHead f) = '[]
    type ToBinds (BuiltinHead f) = '[]

    toTypeAst _ = mkTyBuiltin @_ @f ()
    {-# INLINE toTypeAst #-}

-- | Delete all @x@s from a list.
type family Delete x xs :: [a] where
    Delete _ '[]       = '[]
    Delete x (x ': xs) = Delete x xs
    Delete x (y ': xs) = y ': Delete x xs

-- | Delete all elements appearing in the first list from the second one and concatenate the lists.
type family Merge xs ys :: [a] where
    Merge '[]       ys = ys
    Merge (x ': xs) ys = x ': Delete x (Merge xs ys)

-- There's no sensible way to provide a 'KnownTypeAst' instance for a type-level list, so we
-- create a separate type family. We could have a single type family on the top level for both
-- 'ToBinds' and 'ListToBinds', but then we'd lose a very convenient default of each type from the
-- universe returning an empty list from 'ToBinds' and the user would need to do provide a
-- @type instance@ themselves (which is no big deal, but it's nicer not to ask the user to do that).
-- | Collect all unique variables (a variable consists of a textual name, a unique and a kind)
-- in a list.
type ListToBinds :: forall a. [a] -> [GADT.Some TyNameRep]
type family ListToBinds xs
type instance ListToBinds '[]       = '[]
type instance ListToBinds (x ': xs) = Merge (ToBinds x) (ListToBinds xs)

-- | A constraint for \"@a@ is a 'KnownType' by means of being included in @uni@\".
type KnownBuiltinTypeIn uni term a = (HasConstantIn uni term, GShow uni, GEq uni, uni `Contains` a)

-- | A constraint for \"@a@ is a 'KnownType' by means of being included in @UniOf term@\".
type KnownBuiltinType term a = KnownBuiltinTypeIn (UniOf term) term a

{- Note [Performance of KnownTypeIn instances]
It's critically important that 'readKnown' runs in the concrete 'Either' rather than a general
'MonadError'. Changing from the latter to the former gave us a speedup of up to 19%, see
https://github.com/input-output-hk/plutus/pull/4307

The same does not apply to 'makeKnown' however and so we keep 'MonadError' there, see
https://github.com/input-output-hk/plutus/pull/4308
Although there's a different kind of inlining that helps in case of 'makeKnown', see the first
commit and the first comment of https://github.com/input-output-hk/plutus/pull/4251
We don't have it merged currently though, because there's a hope for a better solution.

Even though we don't use 'makeKnown' and 'readKnown' directly over concrete types, it's still
beneficial to inline them, because otherwise GHC compiles each of them to two definitions
(one calling the other) for some reason. So always add an @INLINE@ pragma to all definitions
of 'makeKnown' and 'readKnown' unless you have a specific reason not to.

Similarly, we inline implementations of 'toTypeAst' just to get tidier Core.

Some 'readKnown' implementations require inserting a call to 'oneShot'. E.g. if 'oneShot' is not
used in 'readKnownConstant' then 'GHC pulls @gshow uniExp@ out of the 'Nothing' branch, thus
allocating a thunk of type 'String' that is completely redundant whenever there's no error,
which is the majority of cases. And putting 'oneShot' as the outermost call results in
worse Core.

Any change to an instance of 'KnownTypeIn', even completely trivial, requires looking into the
generated Core, since compilation of these instances is extremely brittle optimization-wise.

Things to watch out for are unnecessary sharing (for example, a @let@ appearing outside of a @case@
allocates a thunk and if that thunk is not referenced inside of one of the branches, then it's
wasteful, especially when it's not referenced in the most commonly chosen branch) and type class
methods not being extracted from the dictionary and used directly instead (i.e. if you see
multiple @pure@ and @>>=@ in the code, that's not good). Note that neither @let@ nor @>>=@ are bad
in general, we certainly do need to allocate thunks occasionally, it's just that when it comes to
builtins this is rarely the case as most of the time we want aggressive inlining and specialization
and the "just compute the damn thing" behavior.
-}

{- Note [Unlifting values of built-in types]
It's trivial to unlift from a term a value of a monomorphic type like 'Integer': just check that
the term is a constant, extract the type tag and check it for equality with the type tag of
'Integer'.

Things work the same way for a fully monomorphized polymorphic type, i.e. @(Integer, Bool@) is not
any different from just 'Integer' unlifting-wise.

However there's no sensible way of unlifting a value of, say, @[a]@ where @a@ in not a built-in
type. So let's say we instantiated @a@ to an @Opaque term rep@ like we do for polymorphic functions
that don't deal with polymorphic built-in types (e.g. `id`, `ifThenElse` etc). That would mean we'd
need to write a function from a @[a]@ for some arbitrary built-in @a@ to @[Opaque term a]@. Which
is really easy to do: it's just @map makeKnown@. But the problem is, unlifting is supposed to be
cheap and that @map@ is O(n), so for example 'MkCons' would become an O(n) operation making
perfectly linear algorithms quadratic. See https://github.com/input-output-hk/plutus/pull/4215 for
how that would look like.

So the problem is that we can't convert in O(1) time a @[a]@ coming from a constant of
statically-unknown type (that @a@ is existential) to @[a']@ where @a'@ is known statically.
Thus it's impossible to instantiate @a@ in Haskell's

    nullList :: [a] -> Bool

so that there's a 'TypeScheme' for this function.

One non-solution would be to instantiate @a@, then recurse on the type, construct a new function
that defers to the original @nullList@ but wraps its argument in a specific way (more on that below)
making it possible to assign a 'TypeScheme' to the resulting function. Astonishingly enough, that
could actually work and if we ever write a paper on builtins, we should mention that example, but:

1. such a trick requires a generic machinery that knows how to check that the head of the builtin
   application is a particular built-in type. We used to have that, but it was just way too slow
2. that would only work for functions that don't care about @a@ at all. But for example when
   elaborating @cons :: a -> [a] -> [a]@ as a Plutus builtin we need to unlift both the arguments
   and check that their @a@s are equal
   (See Note [Representable built-in functions over polymorphic built-in types])
   and it's either way too complex or even impossible to do that automatically within some generic
   machinery

So what we do is we simply require the user to write

    nullList :: Opaque term [a] -> Bool

and unlift a @[a]@ manually within the definition of the builtin. This works, because the
existential @a@ never escapes the definition of the builtin. I.e. it's fine to unpack an existential
and use it immediately without ever exposing the existential parts to the outside and it's not fine
to try to return a value having an existential inside of it, which is what unlifting of @[a]@ would
amount to.

Could we somehow align the unlifting machinery so that it does not construct values of particular
types, but rather feeds them to a continuation or something, so that the existential parts never
try to escape? Maybe, but see point 2 from the above, we do want to get our hands on the particular
universes sometimes and point 1 prevents us from doing that generically, so it doesn't seem like
we could do that within some automated machinery.

Overall, asking the user to manually unlift from @Opaque term [a]@ is just always going to be
faster than any kind of fancy encoding.
-}

-- See Note [Unlifting values of built-in types].
-- | Convert a constant embedded into a PLC term to the corresponding Haskell value.
readKnownConstant
    :: forall term a err cause. (AsUnliftingError err, KnownBuiltinType term a)
    => Maybe cause -> term -> Either (ErrorWithCause err cause) a
-- See Note [Performance of KnownTypeIn instances].
readKnownConstant mayCause term = asConstant mayCause term >>= oneShot \case
    Some (ValueOf uniAct x) -> do
        let uniExp = knownUni @_ @(UniOf term) @a
        case uniAct `geq` uniExp of
            Just Refl -> pure x
            Nothing   -> do
                let err = fromString $ concat
                        [ "Type mismatch: "
                        , "expected: " ++ gshow uniExp
                        , "; actual: " ++ gshow uniAct
                        ]
                throwingWithCause _UnliftingError err mayCause
{-# INLINE readKnownConstant #-}

-- See Note [Performance of KnownTypeIn instances].
-- We use @default@ for providing instances for built-in types instead of @DerivingVia@, because
-- the latter breaks on @m term@ (and for brevity).
-- | Haskell types known to exist on the PLC side.
-- Both the methods take a @Maybe cause@ argument to report the cause of a potential failure.
-- @cause@ is different to @term@ to support evaluators that distinguish between terms and values
-- (@makeKnown@ normally constructs a value, but it's convenient to report the cause of a failure
-- as a term). Note that an evaluator might require the cause to be computed lazily for best
-- performance on the happy path and @Maybe@ ensures that even if we somehow force the argument,
-- the cause stored in it is not forced due to @Maybe@ being a lazy data type.
-- Note that 'KnownTypeAst' is not a superclass of 'KnownTypeIn'. This is due to the fact that
-- polymorphic built-in types are only liftable/unliftable when they're fully monomorphized, while
-- 'toTypeAst' works for polymorphic built-in types that have type variables in them, and so the
-- constraints are completely different in the two cases and we keep the two classes apart
-- (there doesn't seem to be any cons to that).
class uni ~ UniOf term => KnownTypeIn uni term a where
    -- | Convert a Haskell value to the corresponding PLC term.
    -- The inverse of 'readKnown'.
    makeKnown
        :: ( MonadError (ErrorWithCause err cause) m, AsEvaluationFailure err
           )
        => (Text -> m ()) -> Maybe cause -> a -> m term
    default makeKnown
        :: ( MonadError (ErrorWithCause err cause) m
           , KnownBuiltinType term a
           )
        => (Text -> m ()) -> Maybe cause -> a -> m term
    -- Forcing the value to avoid space leaks. Note that the value is only forced to WHNF,
    -- so care must be taken to ensure that every value of a type from the universe gets forced
    -- to NF whenever it's forced to WHNF.
    makeKnown _ _ x = pure . fromConstant . someValue $! x
    {-# INLINE makeKnown #-}

    -- | Convert a PLC term to the corresponding Haskell value.
    -- The inverse of 'makeKnown'.
    readKnown
        :: ( AsUnliftingError err, AsEvaluationFailure err
           )
        => Maybe cause -> term -> Either (ErrorWithCause err cause) a
    default readKnown
        :: ( AsUnliftingError err
           , KnownBuiltinType term a
           )
        => Maybe cause -> term -> Either (ErrorWithCause err cause) a
    -- If 'inline' is not used, proper inlining does not happen for whatever reason.
    readKnown = inline readKnownConstant
    {-# INLINE readKnown #-}

-- | Haskell types known to exist on the PLC side. See 'KnownTypeIn'.
type KnownType term a = (KnownTypeAst (UniOf term) a, KnownTypeIn (UniOf term) term a)

-- | Same as 'readKnown', but the cause of a potential failure is the provided term itself.
readKnownSelf
    :: ( KnownType term a
       , AsUnliftingError err, AsEvaluationFailure err
       )
    => term -> Either (ErrorWithCause err term) a
readKnownSelf term = readKnown (Just term) term

-- | For providing a 'KnownTypeIn' instance for a built-in type it's enough for that type to satisfy
-- 'KnownBuiltinTypeIn', hence the definition.
class    (forall term. KnownBuiltinTypeIn uni term a => KnownTypeIn uni term a) =>
    ImplementedKnownBuiltinTypeIn uni a
instance (forall term. KnownBuiltinTypeIn uni term a => KnownTypeIn uni term a) =>
    ImplementedKnownBuiltinTypeIn uni a

-- | An instance of this class not having any constraints ensures that every type
-- (according to 'Everywhere') from the universe has a 'KnownTypeIn' instance.
class uni `Everywhere` ImplementedKnownBuiltinTypeIn uni => TestTypesFromTheUniverseAreAllKnown uni

-- | A transformer for fitting a monad not carrying the cause of a failure into 'makeKnown'.
newtype NoCauseT (term :: GHC.Type) m a = NoCauseT
    { unNoCauseT :: m a
    } deriving newtype (Functor, Applicative, Monad)

instance (MonadError err m, AsEvaluationFailure err) =>
            MonadError (ErrorWithCause err term) (NoCauseT term m) where
    throwError _ = NoCauseT $ throwError evaluationFailure
    NoCauseT a `catchError` h =
        NoCauseT $ a `catchError` \err ->
            unNoCauseT . h $ ErrorWithCause err Nothing

-- | Same as 'makeKnown', but allows for neither emitting nor storing the cause of a failure.
-- For example the monad can be simply 'EvaluationResult'.
makeKnownOrFail :: (KnownType term a, MonadError err m, AsEvaluationFailure err) => a -> m term
makeKnownOrFail = unNoCauseT . makeKnown (\_ -> pure ()) Nothing

instance KnownTypeAst uni a => KnownTypeAst uni (EvaluationResult a) where
    type ToHoles (EvaluationResult a) = '[TypeHole a]
    type ToBinds (EvaluationResult a) = ToBinds a

    toTypeAst _ = toTypeAst $ Proxy @a
    {-# INLINE toTypeAst #-}

instance KnownTypeIn uni term a => KnownTypeIn uni term (EvaluationResult a) where
    makeKnown _    mayCause EvaluationFailure     = throwingWithCause _EvaluationFailure () mayCause
    makeKnown emit mayCause (EvaluationSuccess x) = makeKnown emit mayCause x
    {-# INLINE makeKnown #-}

    -- Catching 'EvaluationFailure' here would allow *not* to short-circuit when 'readKnown' fails
    -- to read a Haskell value of type @a@. Instead, in the denotation of the builtin function
    -- the programmer would be given an explicit 'EvaluationResult' value to handle, which means
    -- that when this value is 'EvaluationFailure', a PLC 'Error' was caught.
    -- I.e. it would essentially allow us to catch errors and handle them in a programmable way.
    -- We forbid this, because it complicates code and isn't supported by evaluation engines anyway.
    readKnown mayCause _ =
        throwingWithCause _UnliftingError "Error catching is not supported" mayCause
    {-# INLINE readKnown #-}

instance KnownTypeAst uni a => KnownTypeAst uni (Emitter a) where
    type ToHoles (Emitter a) = '[TypeHole a]
    type ToBinds (Emitter a) = ToBinds a

    toTypeAst _ = toTypeAst $ Proxy @a
    {-# INLINE toTypeAst #-}

instance KnownTypeIn uni term a => KnownTypeIn uni term (Emitter a) where
    makeKnown emit mayCause (Emitter k) = k emit >>= makeKnown emit mayCause
    {-# INLINE makeKnown #-}

    -- TODO: we really should tear 'KnownType' apart into two separate type classes.
    readKnown mayCause _ = throwingWithCause _UnliftingError "Can't unlift an 'Emitter'" mayCause
    {-# INLINE readKnown #-}

-- | For unlifting from the 'Constant' constructor when the stored value is of a monomorphic
-- built-in type
--
-- The @rep@ parameter specifies how the type looks on the PLC side (i.e. just like with
-- @Opaque term rep@).
newtype SomeConstant uni (rep :: GHC.Type) = SomeConstant
    { unSomeConstant :: Some (ValueOf uni)
    }

instance KnownTypeAst uni rep => KnownTypeAst uni (SomeConstant uni rep) where
    type ToHoles (SomeConstant _ rep) = '[RepHole rep]
    type ToBinds (SomeConstant _ rep) = ToBinds rep

    toTypeAst _ = toTypeAst $ Proxy @rep
    {-# INLINE toTypeAst #-}

instance HasConstantIn uni term => KnownTypeIn uni term (SomeConstant uni rep) where
    makeKnown _ _ = coerceArg $ pure . fromConstant
    {-# INLINE makeKnown #-}

    readKnown = coerceVia (\asC mayCause -> fmap SomeConstant . asC mayCause) asConstant
    {-# INLINE readKnown #-}

toTyNameAst
    :: forall text uniq. (KnownSymbol text, KnownNat uniq)
    => Proxy ('TyNameRep text uniq) -> TyName
toTyNameAst _ =
    TyName $ Name
        (Text.pack $ symbolVal @text Proxy)
        (Unique . fromIntegral $ natVal @uniq Proxy)

instance (name ~ 'TyNameRep text uniq, KnownSymbol text, KnownNat uniq) =>
            KnownTypeAst uni (TyVarRep name) where
    type ToHoles (TyVarRep name) = '[]
    type ToBinds (TyVarRep name) = '[ 'GADT.Some name ]

    toTypeAst _ = TyVar () . toTyNameAst $ Proxy @('TyNameRep text uniq)
    {-# INLINE toTypeAst #-}

instance (KnownTypeAst uni fun, KnownTypeAst uni arg) => KnownTypeAst uni (TyAppRep fun arg) where
    type ToHoles (TyAppRep fun arg) = '[RepHole fun, RepHole arg]
    type ToBinds (TyAppRep fun arg) = Merge (ToBinds fun) (ToBinds arg)

    toTypeAst _ = TyApp () (toTypeAst $ Proxy @fun) (toTypeAst $ Proxy @arg)
    {-# INLINE toTypeAst #-}

instance
        ( name ~ 'TyNameRep @kind text uniq, KnownSymbol text, KnownNat uniq
        , KnownKind kind, KnownTypeAst uni a
        ) => KnownTypeAst uni (TyForallRep name a) where
    type ToHoles (TyForallRep name a) = '[RepHole a]
    type ToBinds (TyForallRep name a) = Delete ('GADT.Some name) (ToBinds a)

    toTypeAst _ =
        TyForall ()
            (toTyNameAst $ Proxy @('TyNameRep text uniq))
            (runSingKind $ knownKind @kind)
            (toTypeAst $ Proxy @a)
    {-# INLINE toTypeAst #-}

instance KnownTypeAst uni rep => KnownTypeAst uni (Opaque term rep) where
    type ToHoles (Opaque _ rep) = '[RepHole rep]
    type ToBinds (Opaque _ rep) = ToBinds rep

    toTypeAst _ = toTypeAst $ Proxy @rep
    {-# INLINE toTypeAst #-}

instance uni ~ UniOf term => KnownTypeIn uni term (Opaque term rep) where
    makeKnown _ _ = coerceArg pure  -- A faster @pure . Opaque@.
    {-# INLINE makeKnown #-}

    readKnown _ = coerceArg pure  -- A faster @pure . Opaque@.
    {-# INLINE readKnown #-}

-- Custom type errors to guide the programmer adding a new built-in function.
-- We cover a lot of cases here, but some are missing, for example we do not attempt to detect
-- higher-kinded type variables, which means that if your function returns an @m a@ we can neither
-- instantiate @m@ (which is impossible anyway: it could be 'EvaluationResult' or 'Emitter'
-- or else), nor report that higher-kinded type variables are not allowed and suggest
-- to instantiate such variables manually. In general, we do not attempt to look inside type
-- applications (as it's a rather hard thing to do) and so a type variable inside, say, a list
-- does not get instantiated, hence the custom type error does not get triggered (as it's only
-- triggered for instantiated type variables) and the user gets a standard unhelpful GHC error.

-- We don't have @Unsatisfiable@ yet (https://github.com/ghc-proposals/ghc-proposals/pull/433).
-- | To be used when there's a 'TypeError' in the context. The condition is not checked as there's
-- no way we could do that.
underTypeError :: void
underTypeError = error "Panic: a 'TypeError' was bypassed"

type NoStandalonePolymorphicDataErrMsg =
    'Text "Plutus type variables can't directly appear inside built-in types" ':$$:
    'Text "Are you trying to define a polymorphic built-in function over a polymorphic type?" ':$$:
    'Text "In that case you need to wrap all polymorphic built-in types having type variables" ':<>:
    'Text " in them with either ‘SomeConstant’ or ‘Opaque’ depending on whether its the type" ':<>:
    'Text " of an argument or the type of the result, respectively"

instance TypeError NoStandalonePolymorphicDataErrMsg => uni `Contains` TyVarRep where
    knownUni = underTypeError

type NoConstraintsErrMsg =
    'Text "Built-in functions are not allowed to have constraints" ':$$:
    'Text "To fix this error instantiate all constrained type variables"

instance TypeError NoConstraintsErrMsg => Eq (Opaque term rep) where
    (==) = underTypeError

instance TypeError NoConstraintsErrMsg => Ord (Opaque term rep) where
    compare = underTypeError

instance TypeError NoConstraintsErrMsg => Num (Opaque term rep) where
    (+)         = underTypeError
    (*)         = underTypeError
    abs         = underTypeError
    signum      = underTypeError
    fromInteger = underTypeError
    negate      = underTypeError

instance TypeError NoConstraintsErrMsg => Enum (Opaque term rep) where
    toEnum   = underTypeError
    fromEnum = underTypeError

instance TypeError NoConstraintsErrMsg => Real (Opaque term rep) where
    toRational = underTypeError

instance TypeError NoConstraintsErrMsg => Integral (Opaque term rep) where
    quotRem   = underTypeError
    divMod    = underTypeError
    toInteger = underTypeError

instance TypeError NoConstraintsErrMsg => Bounded (Opaque term rep) where
    minBound = underTypeError
    maxBound = underTypeError

instance TypeError NoConstraintsErrMsg => Ix (Opaque term rep) where
    range   = underTypeError
    index   = underTypeError
    inRange = underTypeError

instance TypeError NoConstraintsErrMsg => Semigroup (Opaque term rep) where
    (<>) = underTypeError

instance TypeError NoConstraintsErrMsg => Monoid (Opaque term rep) where
    mempty = underTypeError

-- Utils

-- | Coerce the second argument to the result type of the first one. The motivation for this
-- function is that it's often more annoying to explicitly specify a target type for 'coerce' than
-- to constructor an explicit coercion function, so this combinator can be used in cases like that.
-- Plus the code reads better, as it becomes clear what and where gets wrapped/unwrapped.
coerceVia :: Coercible a b => (a -> b) -> a -> b
coerceVia _ = coerce
{-# INLINE coerceVia #-}

-- | Same as @\f -> f . coerce@, but does not create any closures and so is completely free.
coerceArg :: Coercible a b => (a -> r) -> b -> r
coerceArg = coerce
{-# INLINE coerceArg #-}
