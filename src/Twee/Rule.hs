{-# LANGUAGE TypeFamilies, FlexibleContexts, RecordWildCards, CPP, BangPatterns, OverloadedStrings, DeriveGeneric, MultiParamTypeClasses, ScopedTypeVariables #-}
module Twee.Rule where

#include "errors.h"
import Twee.Base
import Twee.Constraints
import qualified Twee.Index as Index
import Twee.Index(Index)
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Strict
import Data.Maybe
import Data.List
import Twee.Utils
import qualified Data.Set as Set
import Data.Set(Set)
import qualified Twee.Term as Term
import GHC.Generics
import Data.Ord

--------------------------------------------------------------------------------
-- Rewrite rules.
--------------------------------------------------------------------------------

data Rule f =
  Rule {
    orientation :: !(Orientation f),
    lhs :: {-# UNPACK #-} !(Term f),
    rhs :: {-# UNPACK #-} !(Term f) }
  deriving (Eq, Ord, Show, Generic)
type RuleOf a = Rule (ConstantOf a)

data Orientation f =
    Oriented
  | WeaklyOriented {-# UNPACK #-} !(Fun f) [Term f]
  | Permutative [(Term f, Term f)]
  | Unoriented
  deriving Show

instance Eq (Orientation f) where _ == _ = True
instance Ord (Orientation f) where compare _ _ = EQ

oriented :: Orientation f -> Bool
oriented Oriented{} = True
oriented WeaklyOriented{} = True
oriented _ = False

weaklyOriented :: Orientation f -> Bool
weaklyOriented WeaklyOriented{} = True
weaklyOriented _ = False

instance Symbolic (Rule f) where
  type ConstantOf (Rule f) = f

instance f ~ g => Has (Rule f) (Term g) where
  the = lhs

instance Symbolic (Orientation f) where
  type ConstantOf (Orientation f) = f

  termsDL Oriented = mzero
  termsDL (WeaklyOriented _ ts) = termsDL ts
  termsDL (Permutative ts) = termsDL ts
  termsDL Unoriented = mzero

  subst_ _   Oriented = Oriented
  subst_ sub (WeaklyOriented min ts) = WeaklyOriented min (subst_ sub ts)
  subst_ sub (Permutative ts) = Permutative (subst_ sub ts)
  subst_ _   Unoriented = Unoriented

instance PrettyTerm f => Pretty (Rule f) where
  pPrint (Rule or l r) =
    pPrint l <+> text (showOrientation or) <+> pPrint r
    where
      showOrientation Oriented = "->"
      showOrientation WeaklyOriented{} = "~>"
      showOrientation Permutative{} = "<->"
      showOrientation Unoriented = "="

--------------------------------------------------------------------------------
-- Equations.
--------------------------------------------------------------------------------

data Equation f =
  {-# UNPACK #-} !(Term f) :=: {-# UNPACK #-} !(Term f)
  deriving (Eq, Ord, Show, Generic)
type EquationOf a = Equation (ConstantOf a)

instance Symbolic (Equation f) where
  type ConstantOf (Equation f) = f

instance PrettyTerm f => Pretty (Equation f) where
  pPrint (x :=: y) = pPrint x <+> text "=" <+> pPrint y

instance Sized f => Sized (Equation f) where
  size (x :=: y) = size x + size y

-- Order an equation roughly left-to-right.
-- However, there is no guarantee that the result is oriented.
order :: Function f => Equation f -> Equation f
order (l :=: r)
  | l == r = l :=: r
  | otherwise =
    case compare (size l) (size r) of
      LT -> r :=: l
      GT -> l :=: r
      EQ -> if lessEq l r then r :=: l else l :=: r

-- Turn a rule into an equation.
unorient :: Rule f -> Equation f
unorient (Rule _ l r) = l :=: r

-- Turn an equation into a set of rules.
-- Along with each rule, returns a function which transforms a proof
-- of the equation into a proof of the rule.
orient :: forall f. Function f => Equation f -> [(Rule f, Proof f -> Proof f)]
orient (l :=: r) | l == r = []
orient (l :=: r) =
  -- If we have an equation where some variables appear only on one side, e.g.:
  --   f x y = g x z
  -- then replace it with the equations:
  --   f x y = f x k
  --   g x z = g x k
  --   f x k = g x k
  -- where k is an arbitrary constant
  [ (makeRule l r',
     \pf -> erase rs pf)
  | ord /= Just LT && ord /= Just EQ ] ++
  [ (makeRule r l',
     \pf -> backwards (erase ls pf))
  | ord /= Just GT && ord /= Just EQ ] ++
  [ (makeRule l l',
     \pf -> pf ++ backwards (erase ls pf))
  | not (null ls), ord /= Just GT ] ++
  [ (makeRule r r',
     \pf -> backwards pf ++ erase rs pf)
  | not (null rs), ord /= Just LT ]
  where
    ord = orientTerms l' r'
    l' = erase ls l
    r' = erase rs r
    ls = usort (vars l) \\ usort (vars r)
    rs = usort (vars r) \\ usort (vars l)

    erase :: (Symbolic a, ConstantOf a ~ f) => [Var] -> a -> a
    erase [] t = t
    erase xs t = subst sub t
      where
        sub = fromMaybe __ $ flattenSubst [(x, minimalTerm) | x <- xs]

-- Turn a pair of terms t and u into a rule t -> u by computing the
-- orientation info (e.g. oriented, permutative or unoriented).
makeRule :: Function f => Term f -> Term f -> Rule f
makeRule t u = Rule o t u
  where
    o | lessEq u t =
        case unify t u of
          Nothing -> Oriented
          Just sub
            | allSubst (\_ (Cons t Empty) -> isMinimal t) sub ->
              WeaklyOriented minimal (map (build . var . fst) (listSubst sub))
            | otherwise -> Unoriented
      | lessEq t u = ERROR("wrongly-oriented rule")
      | not (null (usort (vars u) \\ usort (vars t))) =
        ERROR("unbound variables in rule")
      | Just ts <- evalStateT (makePermutative t u) [],
        permutativeOK t u ts =
        Permutative ts
      | otherwise = Unoriented

    permutativeOK _ _ [] = True
    permutativeOK t u ((Var x, Var y):xs) =
      lessIn model u t == Just Strict &&
      permutativeOK t' u' xs
      where
        model = modelFromOrder [Variable y, Variable x]
        sub x' = if x == x' then var y else var x'
        t' = subst sub t
        u' = subst sub u

    makePermutative t u = do
      msub <- gets flattenSubst
      sub  <- lift msub
      aux (subst sub t) (subst sub u)
        where
          aux (Var x) (Var y)
            | x == y = return []
            | otherwise = do
              modify ((x, build $ var y):)
              return [(build $ var x, build $ var y)]

          aux (App f ts) (App g us)
            | f == g =
              fmap concat (zipWithM makePermutative (unpack ts) (unpack us))

          aux _ _ = mzero

-- Apply a function to both sides of an equation.
bothSides :: (Term f -> Term f') -> Equation f -> Equation f'
bothSides f (t :=: u) = f t :=: f u

-- Is an equation of the form t = t?
trivial :: Eq f => Equation f -> Bool
trivial (t :=: u) = t == u

--------------------------------------------------------------------------------
-- Extra-fast rewriting, without proof output or unorientable rules.
--------------------------------------------------------------------------------

-- Compute the normal form of a term wrt only oriented rules.
{-# INLINEABLE simplify #-}
simplify :: (Function f, Has a (Rule f)) => Index f a -> Term f -> Term f
simplify !idx !t = {-# SCC simplify #-} simplify1 idx t

{-# INLINEABLE simplify1 #-}
simplify1 :: (Function f, Has a (Rule f)) => Index f a -> Term f -> Term f
simplify1 idx t
  | t == u = t
  | otherwise = simplify idx u
  where
    u = build (simp (singleton t))

    simp Empty = mempty
    simp (Cons (Var x) t) = var x `mappend` simp t
    simp (Cons t u)
      | Just (rule, sub) <- simpleRewrite idx t =
        Term.subst sub (rhs rule) `mappend` simp u
    simp (Cons (App f ts) us) =
      app f (simp ts) `mappend` simp us

-- Check if a term can be simplified.
{-# INLINEABLE canSimplify #-}
canSimplify :: (Function f, Has a (Rule f)) => Index f a -> Term f -> Bool
canSimplify idx t = canSimplifyList idx (singleton t)

{-# INLINEABLE canSimplifyList #-}
canSimplifyList :: (Function f, Has a (Rule f)) => Index f a -> TermList f -> Bool
canSimplifyList idx t =
  {-# SCC canSimplifyList #-}
  any (isJust . simpleRewrite idx) (filter isApp (subtermsList t))

-- Find a simplification step that applies to a term.
{-# INLINEABLE simpleRewrite #-}
simpleRewrite :: (Function f, Has a (Rule f)) => Index f a -> Term f -> Maybe (Rule f, Subst f)
simpleRewrite idx t =
  -- Use instead of maybeToList to make fusion work
  foldr (\x _ -> Just x) Nothing $ do
    rule <- the <$> Index.approxMatches t idx
    guard (oriented (orientation rule))
    sub <- maybeToList (match (lhs rule) t)
    guard (reducesOriented rule sub)
    return (rule, sub)

--------------------------------------------------------------------------------
-- Rewriting, with proof output.
--------------------------------------------------------------------------------

type Strategy f = Term f -> [Reduction f]

-- A multi-step rewrite proof t ->* u
data Reduction f =
    -- Apply a single rewrite rule to the root of a term
    Step {-# UNPACK #-} !VersionedId !(Rule f) !(Subst f)
    -- Transivitity
  | Trans !(Reduction f) !(Reduction f)
    -- Parallel rewriting given a list of (position, rewrite) pairs
    -- and the initial term
  | Parallel ![(Int, Reduction f)] {-# UNPACK #-} !(Term f)
  deriving Show

-- Two reductions are equal if they rewrite to the same thing.
-- This is useful for normalForms.
instance Eq (Reduction f) where x == y = compare x y == EQ
instance Ord (Reduction f) where
  compare = comparing (\p -> result p)

instance Symbolic (Reduction f) where
  type ConstantOf (Reduction f) = f
  termsDL (Step _ rule sub) = termsDL rule `mplus` termsDL sub
  termsDL (Trans p q) = termsDL p `mplus` termsDL q
  termsDL (Parallel rs t) = termsDL (map snd rs) `mplus` termsDL t

  subst_ sub (Step n rule s) = Step n rule (subst_ sub s)
  subst_ sub (Trans p q) = Trans (subst_ sub p) (subst_ sub q)
  subst_ sub (Parallel rs t) =
    Parallel
      [ (pathToPosition u (positionToPath t n),
         subst_ sub r)
      | (n, r) <- rs ]
      u
    where
      u = subst sub t

instance PrettyTerm f => Pretty (Reduction f) where
  pPrint = pPrintReduction

pPrintReduction :: PrettyTerm f => Reduction f -> Doc
pPrintReduction p =
  case flatten p of
    [p] -> pp p
    ps -> pPrint (map pp ps)
  where
    flatten (Trans p q) = flatten p ++ flatten q
    flatten p = [p]

    pp p = sep [pp0 p, nest 2 (text "giving" <+> pPrint (result p))]
    pp0 (Step _ rule sub) =
      sep [pPrint rule,
           nest 2 (text "at" <+> pPrint sub)]
    pp0 (Parallel [] _) = text "refl"
    pp0 (Parallel [(0, p)] _) = pp0 p
    pp0 (Parallel ps _) =
      sep (punctuate (text " and")
        [hang (pPrint n <+> text "->") 2 (pPrint p) | (n, p) <- ps])

-- Find the initial term of a rewrite proof
initial :: Reduction f -> Term f
initial (Step _ r sub) = subst sub (lhs r)
initial (Trans p _) = initial p
initial (Parallel _ t) = t

-- Find the final term of a rewrite proof
result :: Reduction f -> Term f
result (Parallel [] t) = t
result (Trans _ p) = result p
result t = {-# SCC result_emitReduction #-} build (emitReduction t)
  where
    emitReduction (Step _ r sub) = Term.subst sub (rhs r)
    emitReduction (Trans _ p) = emitReduction p
    emitReduction (Parallel ps t) = emitParallel 0 ps (singleton t)

    emitParallel !_ _ _ | False = __
    emitParallel _ _ Empty = mempty
    emitParallel _ [] t = builder t
    emitParallel n ((m, _):_) t  | m >= n + lenList t = builder t
    emitParallel n ps@((m, _):_) (Cons t u) | m >= n + len t =
      builder t `mappend` emitParallel (n + len t) ps u
    emitParallel n ((m, _):ps) t | m < n = emitParallel n ps t
    emitParallel n ((m, p):ps) (Cons t u) | m == n =
      emitReduction p `mappend` emitParallel (n + len t) ps u
    emitParallel n ps (Cons (Var x) u) =
      var x `mappend` emitParallel (n + 1) ps u
    emitParallel n ps (Cons (App f t) u) =
      app f (emitParallel (n+1) ps t) `mappend`
      emitParallel (n + 1 + lenList t) ps u

-- The list of all rewrite rules used in a proof
steps :: Reduction f -> [(Rule f, Subst f)]
steps r = aux r []
  where
    aux (Step _ r sub) = ((r, sub):)
    aux (Trans p q) = aux p . aux q
    aux (Parallel ps _) = foldr (.) id (map (aux . snd) ps)

--------------------------------------------------------------------------------
-- Strategy combinators.
--------------------------------------------------------------------------------

-- Normalise a term wrt a particular strategy.
{-# INLINE normaliseWith #-}
normaliseWith :: PrettyTerm f => (Term f -> Bool) -> Strategy f -> Term f -> Reduction f
normaliseWith ok strat t = {-# SCC normaliseWith #-} res
  where
    res = aux 0 (Parallel [] t) t
    aux 1000 p _ =
      ERROR("Possibly nonterminating rewrite:\n" ++
            prettyShow p)
    aux n p t =
      case anywhere1 strat (singleton t) of
        [] -> p
        rs ->
          let
            q = p `Trans` Parallel rs t
            u = result q
          in
            if ok u then aux (n+1) q u else p

-- Compute all normal forms of a term wrt a particular strategy.
{-# INLINEABLE normalForms #-}
normalForms :: Function f => Strategy f -> [Reduction f] -> Set (Reduction f)
normalForms strat ps = {-# SCC normalForms #-} go Set.empty Set.empty ps
  where
    go _ norm [] = norm
    go dead norm (p:ps)
      | p `Set.member` dead = go dead norm ps
      | p `Set.member` norm = go dead norm ps
      | null qs = go dead (Set.insert p norm) ps
      | otherwise =
        go (Set.insert p dead) norm (qs ++ ps)
      where
        qs = [ p `Trans` q | q <- anywhere strat (result p) ]

-- Apply a strategy anywhere in a term.
anywhere :: Strategy f -> Strategy f
anywhere strat t = aux 0 (singleton t)
  where
    aux !_ Empty = []
    aux n (Cons Var{} u) = aux (n+1) u
    aux n (ConsSym u v) =
      [Parallel [(n,p)] t | !p <- strat u] ++ aux (n+1) v

-- Apply a strategy to all children of the root function.
nested :: Strategy f -> Strategy f
nested strat t = [Parallel [(1,p)] t | !p <- aux 0 (children t)]
  where
    aux !_ Empty = []
    aux n (Cons Var{} u) = aux (n+1) u
    aux n (Cons u v) =
      [Parallel [(n,p)] t | !p <- strat u] ++ aux (n+len t) v

-- A version of 'anywhere' which does parallel reduction.
{-# INLINE anywhere1 #-}
anywhere1 :: PrettyTerm f => Strategy f -> TermList f -> [(Int, Reduction f)]
anywhere1 strat t = aux [] 0 t
  where
    aux _ !_ !_ | False = __
    aux ps _ Empty = reverse ps
    aux ps n (Cons (Var _) t) = aux ps (n+1) t
    aux ps n (Cons t u) | (!q):_ <- strat t =
      aux ((n, q):ps) (n+len t) u
    aux ps n (ConsSym _ t) =
      aux ps (n+1) t

--------------------------------------------------------------------------------
-- Basic strategies. These only apply at the root of the term.
--------------------------------------------------------------------------------

-- A strategy which rewrites using an index.
{-# INLINE rewrite #-}
rewrite :: (Function f, Has a (Rule f), Has a VersionedId) => (Rule f -> Subst f -> Bool) -> Index f a -> Strategy f
rewrite p rules t = do
  rule <- Index.approxMatches t rules
  tryRule p rule t

-- A strategy which applies one rule only.
{-# INLINEABLE tryRule #-}
tryRule :: (Function f, Has a (Rule f), Has a VersionedId) => (Rule f -> Subst f -> Bool) -> a -> Strategy f
tryRule p rule t = do
  sub <- maybeToList (match (lhs (the rule)) t)
  guard (p (the rule) sub)
  return (Step (the rule) (the rule) sub)

-- Check if a rule can be applied, given an ordering <= on terms.
{-# INLINEABLE reducesWith #-}
reducesWith :: Function f => (Term f -> Term f -> Bool) -> Rule f -> Subst f -> Bool
reducesWith _ (Rule Oriented _ _) _ = True
reducesWith _ (Rule (WeaklyOriented min ts) _ _) sub =
  -- Be a bit careful here not to build new terms
  -- (reducesWith is used in simplify).
  -- This is the same as:
  --   any (not . isMinimal) (subst sub ts)
  any (not . isMinimal . expand) ts
  where
    expand t@(Var x) = fromMaybe t (Term.lookup x sub)
    expand t = t

    isMinimal (App f Empty) = f == min
    isMinimal _ = False
reducesWith p (Rule (Permutative ts) _ _) sub =
  aux ts
  where
    aux [] = False
    aux ((t, u):ts)
      | t' == u' = aux ts
      | otherwise = p u' t'
      where
        t' = subst sub t
        u' = subst sub u
reducesWith p (Rule Unoriented t u) sub =
  p u' t' && u' /= t'
  where
    t' = subst sub t
    u' = subst sub u

-- Check if a rule can be applied normally.
{-# INLINEABLE reduces #-}
reduces :: Function f => Rule f -> Subst f -> Bool
reduces rule sub = reducesWith lessEq rule sub

-- Check if a rule can be applied and is oriented.
{-# INLINEABLE reducesOriented #-}
reducesOriented :: Function f => Rule f -> Subst f -> Bool
reducesOriented rule sub =
  oriented (orientation rule) && reducesWith undefined rule sub

-- Check if a rule can be applied in various circumstances.
{-# INLINEABLE reducesInModel #-}
reducesInModel :: Function f => Model f -> Rule f -> Subst f -> Bool
reducesInModel cond rule sub =
  reducesWith (\t u -> isJust (lessIn cond t u)) rule sub

{-# INLINEABLE reducesSkolem #-}
reducesSkolem :: Function f => Rule f -> Subst f -> Bool
reducesSkolem rule sub =
  reducesWith (\t u -> lessEq (subst skolemise t) (subst skolemise u)) rule sub
  where
    skolemise = con . skolem

----------------------------------------------------------------------
-- Equational proofs.
----------------------------------------------------------------------

type Proof f = [ProofStep f]
data ProofStep f =
    Forwards (Reduction f)
  | Backwards (Reduction f)
  | Axiom String
  deriving Show

instance Symbolic (ProofStep f) where
  type ConstantOf (ProofStep f) = f
  termsDL (Forwards p) = termsDL p
  termsDL (Backwards p) = termsDL p
  termsDL Axiom{} = mempty

  subst_ sub (Forwards p) = Forwards (subst_ sub p)
  subst_ sub (Backwards p) = Backwards (subst_ sub p)
  subst_ sub pf@Axiom{} = pf

-- Turn a proof of t=u into a proof of u=t.
backwards :: Proof f -> Proof f
backwards = reverse . map back
  where
    back (Forwards pf) = Backwards pf
    back (Backwards pf) = Forwards pf
    back (Axiom name) = Axiom name

instance PrettyTerm f => Pretty (ProofStep f) where
  pPrint (Forwards pf) = text "forwards" <+> pPrint pf
  pPrint (Backwards pf) = text "backwards" <+> pPrint pf
  pPrint (Axiom name) = text "axiom" <+> pPrint name
