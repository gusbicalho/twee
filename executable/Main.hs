{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, CPP, GeneralizedNewtypeDeriving, TypeFamilies, RecordWildCards, FlexibleContexts, UndecidableInstances, NondecreasingIndentation, OverloadedStrings #-}
#include "errors.h"

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif

import Control.Monad
import Control.Monad.Trans.State.Strict
import Data.Char
import Data.Either
import Twee hiding (info)
import Twee.Base hiding (char, lookup, (<>))
import Twee.Rule
import Twee.Utils
import Twee.Queue
import Data.Ord
import qualified Twee.Index.Split as Indexes
import qualified Data.Map.Strict as Map
import qualified Twee.KBO as KBO
import qualified Data.Set as Set
import Data.List.Split
import Data.List
import Data.Maybe
import Jukebox.Options
import Jukebox.Toolbox
import Jukebox.Name
import qualified Jukebox.Form as Jukebox
import Jukebox.Form hiding ((:=:), Var, Symbolic(..), Term)
import Twee.Label hiding (Labelled)
import qualified Twee.Label as Label
import Twee.Profile

parseInitialState :: OptionParser (Twee f)
parseInitialState =
  go <$> maxSize <*> general
     <*> groundJoin <*> conn <*> set <*> setGoals <*> tracing <*> moreTracing <*> lweight <*> rweight <*> splits <*> cpSetSize <*> mixFIFO <*> mixPrio <*> skipComposite <*> cancel <*> cancelSize <*> cancelConsts <*> atomicCancellation <*> norm
  where
    go maxSize general groundJoin conn set setGoals tracing moreTracing lweight rweight splits cpSetSize mixFIFO mixPrio skipComposite cancel cancelSize cancelConsts atomicCancellation norm =
      (initialState mixFIFO mixPrio) {
        maxSize = maxSize,
        cpSplits = splits,
        minimumCPSetSize = cpSetSize,
        useGeneralSuperpositions = general,
        useGroundJoining = groundJoin,
        useConnectedness = conn,
        useSetJoining = set,
        useSetJoiningForGoals = setGoals,
        useCancellation = cancel,
        maxCancellationSize = cancelSize,
        renormalise = norm,
        atomicCancellation = atomicCancellation,
        unifyConstantsInCancellation = cancelConsts,
        skipCompositeSuperpositions = skipComposite,
        tracing = tracing,
        moreTracing = moreTracing,
        lhsWeight = lweight,
        rhsWeight = rweight }
    maxSize = flag "max-size" ["Maximum critical pair size"] Nothing (Just <$> argNum)
    general = not <$> bool "no-general-superpositions" ["Disable considering only general superpositions"]
    groundJoin = not <$> bool "no-ground-join" ["Disable ground joinability testing"]
    conn = not <$> bool "no-connectedness" ["Disable connectedness testing"]
    set = bool "set-join" ["Join by computing set of normal forms"]
    setGoals = not <$> bool "no-set-join-goals" ["Disable joining goals by computing set of normal forms"]
    tracing = not <$> bool "no-tracing" ["Disable tracing output"]
    moreTracing = bool "more-tracing" ["Produce even more tracing output"]
    lweight = flag "lhs-weight" ["Weight given to LHS of critical pair (default 4)"] 4 argNum
    rweight = flag "rhs-weight" ["Weight given to RHS of critical pair (default 1)"] 1 argNum
    splits = flag "cp-split" ["Split CP sets into this many pieces on selection (default 20)"] 20 argNum
    norm = not <$> bool "no-normalise-cps" ["Don't normalise critical pairs every so often"]
    cpSetSize = flag "cp-set-minimum" ["Decay CP sets into single CPs when they get this small (default 20)"] 20 argNum
    mixFIFO = flag "mix-fifo" ["Take this many CPs at a time from FIFO (default 0)"] 0 argNum
    mixPrio = flag "mix-prio" ["Take this many CPs at a time from priority queue (default 10)"] 10 argNum
    cancel = not <$> bool "no-cancellation" ["Disable cancellation"]
    cancelSize = flag "max-cancellation-size" ["Maximum size of cancellation laws (default 2)"] (Just 2) (Just <$> argNum)
    cancelConsts = bool "unify-consts-in-cancellation" ["Allow unification with a constant in cancellation"]
    skipComposite = not <$> bool "composite-superpositions" ["Generate composite superpositions"]
    atomicCancellation = not <$> bool "compound-cancellation" ["Allow cancellation laws to have non-atomic RHS"]

data Order = KBO | LPO

parseOrder :: OptionParser Order
parseOrder =
  f <$>
  bool "lpo" ["Use lexicographic path ordering instead of KBO"]
  where
    f False = KBO
    f True  = LPO

parsePrecedence :: OptionParser [String]
parsePrecedence =
  fmap (splitOn ",")
  (flag "precedence" ["List of functions in descending order of precedence"] [] (arg "<function>" "expected a function name" Just))

data Constant =
  Constant {
    conIndex :: Int,
    conArity :: Int,
    conSize  :: Int,
    conName  :: String }
  | Builtin Builtin

data Builtin = CFalse | CTrue | CEquals deriving (Eq, Ord)

instance Eq Constant where
  x == y = x `compare` y == EQ
instance Ord Constant where
  compare Constant{conIndex = x} Constant{conIndex = y} = compare x y
  compare Constant{} Builtin{} = LT
  compare Builtin{} Constant{} = GT
  compare (Builtin x) (Builtin y) = compare x y
instance Sized Constant where
  size Constant{conSize = n} = fromIntegral n
  size Builtin{} = 0
instance Arity Constant where
  arity Constant{conSize = n} = n
  arity (Builtin CEquals) = 2
  arity (Builtin _) = 0

instance Pretty Constant where
  pPrint Constant{conName = name} = text name
  pPrint (Builtin CEquals) = text "$equals"
  pPrint (Builtin CTrue) = text "$true"
  pPrint (Builtin CFalse) = text "$false"
instance PrettyTerm Constant where
  termStyle con@Constant{}
    | not (any isAlphaNum (conName con)) =
      case conArity con of
        1 -> prefix
        2 -> infixStyle 5
        _ -> uncurried
  termStyle _ = uncurried

instance Label.Labelled (Extended Constant) where
  cache = constantCache

{-# NOINLINE constantCache #-}
constantCache :: Cache (Extended Constant)
constantCache = mkCache

instance Minimal (Extended Constant) where
  minimal = auto Minimal

instance Skolem (Extended Constant) where
  skolem x = auto (Skolem x)

instance Ordered (Extended Constant) where
  lessEq = KBO.lessEq
  lessIn = KBO.lessIn

instance Label.Labelled Jukebox.Function where
  cache = functionCache

{-# NOINLINE functionCache #-}
functionCache :: Cache Jukebox.Function
functionCache = mkCache

toTwee :: Problem Clause -> ([Equation Jukebox.Function], [Term Jukebox.Function])
toTwee prob = (lefts eqs, goals)
  where
    eq Input{what = Clause (Bind _ [Pos (t Jukebox.:=: u)])} =
      Left (build (tm t) :=: build (tm u))
    eq Input{what = Clause (Bind _ [Neg (t Jukebox.:=: u)])} =
      Right (build (tm t) :=: build (tm u))
    eq _ = ERROR("Problem is not unit equality")

    eqs = map eq prob

    goals =
      case rights eqs of
        [] -> []
        [t :=: u] -> [t, u]
        _ -> ERROR("Problem is not unit equality")

    tm (Jukebox.Var (Unique x _ _ ::: _)) =
      var (V (fromIntegral x))
    tm (f :@: ts) =
      fun (auto f) (map tm ts)

addNarrowing ::
  ([Equation (Extended Constant)], [Term (Extended Constant)]) ->
  ([Equation (Extended Constant)], [Term (Extended Constant)])
addNarrowing (axioms, goals)
  | length goals < 2 = (axioms, map build [con false, con true])
    where
      false  = auto (Function (Builtin CFalse))
      true   = auto (Function (Builtin CTrue))
addNarrowing (axioms, goals)
  | length goals >= 2 && all isGround goals = (axioms, goals)
addNarrowing (axioms, [t, u])
  | otherwise = (axioms ++ equalities, map build [con false, con true])
    where
      false  = auto (Function (Builtin CFalse))
      true   = auto (Function (Builtin CTrue))
      equals = auto (Function (Builtin CEquals))

      equalities =
        [build (fun equals [var (V 0), var (V 0)]) :=: build (con true),
         build (fun equals [t, u]) :=: build (con false)]
addNarrowing _ =
  ERROR("Don't know how to handle several non-ground goals")

runTwee :: Twee (Extended Constant) -> Order -> [String] -> Problem Clause -> IO Answer
runTwee state _order precedence obligs = stampM "twee" $ do
  let (axioms0, goals0) = toTwee obligs
      prec c = (isNothing (elemIndex (base c) precedence),
                fmap negate (elemIndex (base c) precedence),
                negate (occ (auto c) (axioms0, goals0)))
      fs0 = map fromFun (usort (funs (axioms0, goals0)))
      fs1 = sortBy (comparing prec) fs0
      fs2 = zipWith (\i (c ::: (FunType args _)) -> Constant i (length args) 1 (show c)) [1..] fs1
      m  = Map.fromList (zip fs1 (map Function fs2))
  let replace = build . mapFun (auto . flip (Map.findWithDefault __) m . fromFun)
      axioms1 = [replace t :=: replace u | t :=: u <- axioms0]
      goals1  = map replace goals0
      (axioms2, goals2) = addNarrowing (axioms1, goals1)

  putStrLn "Axioms:"
  mapM_ prettyPrint axioms2
  putStrLn "\nGoals:"
  mapM_ prettyPrint goals2
  putStrLn "\nGo!"

  let
    identical xs = not (Set.null (foldr1 Set.intersection xs))

    loop = do
      res <- complete1
      goals <- gets goals
      when (res && (length goals <= 1 || not (identical goals))) loop

  s <-
    flip execStateT (addGoals (map Set.singleton goals2) state) $ do
      mapM_ newEquation axioms2
      loop

  let rs = map (critical . modelled . peel) (Indexes.elems (labelledRules s))

  putStrLn "\nFinal rules:"
  mapM_ prettyPrint rs
  putStrLn ""

  putStrLn (report s)
  putStrLn "Normalised goal terms:"
  forM_ goals2 $ \t ->
    prettyPrint (Rule Oriented t (result (normalise s t)))

  return $
    case () of
      _ | identical (goals s) -> Unsatisfiable
        | isJust (maxSize s) -> NoAnswer GaveUp
        | otherwise -> NoAnswer GaveUp -- don't trust completeness

main = do
  let twee = Tool "twee" "twee - the Wonderful Equation Engine" "1" "Proves equations."
  join . parseCommandLine twee . tool twee $
    greetingBox twee =>>
    allFilesBox <*>
      (parseProblemBox =>>=
       toFofBox =>>=
       clausifyBox =>>=
       allObligsBox <*>
         (runTwee <$> parseInitialState <*> parseOrder <*> parsePrecedence))
  profile
