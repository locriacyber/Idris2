module TTImp.Interactive.ExprSearch

-- Expression search for interactive editing. There's a lot of similarities
-- with Core.AutoSearch (and we reuse some of it) but I think it's better for
-- them to be entirely separate: AutoSearch is a crucial part of the core
-- therefore it's good for it to be well defined and cleanly separated from
-- everything else, whereas this search mechanism is about finding plausible
-- candidates for programs.

-- We try to find as many results as possible, within the given search
-- depth.

import Core.AutoSearch
import Core.CaseTree
import Core.Context
import Core.Env
import Core.LinearCheck
import Core.Metadata
import Core.Normalise
import Core.Unify
import Core.TT
import Core.Value

import TTImp.Interactive.CaseSplit
import TTImp.Utils

import Data.Bool.Extra
import Data.Either
import Data.List

%default covering

-- Data for building recursive calls - the function name, and the structure
-- of the LHS. Only recursive calls with a different structure are okay.
record RecData where
  constructor MkRecData
  recname : Name -- resolved name
  lhsapp : Term vars

record SearchOpts where
  constructor MkSearchOpts
  holesOK : Bool
  recOK : Bool
  depth : Nat
  inArg : Bool

export
data Search : Type -> Type where
     NoMore : Search a -- no more results
     Result : a -> Core (Search a) -> Search a
       -- ^ a result, and what to do if the result is considered
       -- unacceptable

export
Functor Search where
  map fn NoMore = NoMore
  map fn (Result res next)
      = Result (fn res)
               (do next' <- next
                   pure (map fn next'))

export
one : a -> Core (Search a)
one res = pure $ Result res (pure NoMore)

export
noResult : Core (Search a)
noResult = pure NoMore

export
traverse : (a -> Core b) -> Search a -> Core (Search b)
traverse f NoMore = pure NoMore
traverse f (Result r next)
    = do r' <- f r
         pure (Result r' (do next' <- next
                             traverse f next'))

export
filterS : (a -> Bool) -> Search a -> Core (Search a)
filterS p NoMore = pure NoMore
filterS p (Result r next)
    = do next' <- next
         let fnext = filterS p next'
         if p r
            then pure $ Result r fnext
            else fnext

export
searchN : {auto c : Ref Ctxt Defs} ->
          {auto u : Ref UST UState} ->
          Nat -> Core (Search a) -> Core (List a)
searchN max s
    = tryUnify
         (do res <- s
             xs <- count max res
             pure xs)
         (pure [])
  where
    count : Nat -> Search a -> Core (List a)
    count k NoMore = pure []
    count Z _ = pure []
    count (S Z) (Result a next) = pure [a]
    count (S k) (Result a next) = pure $ a :: !(count k !next)

export
nextResult : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             Core (Search a) -> Core (Maybe (a, Core (Search a)))
nextResult s
    = tryUnify
         (do res <- s
             case res of
                  NoMore => pure Nothing
                  Result r next => pure (Just (r, next)))
         (pure Nothing)

search : {auto c : Ref Ctxt Defs} ->
         {auto m : Ref MD Metadata} ->
         {auto u : Ref UST UState} ->
         FC -> RigCount ->
         SearchOpts -> Maybe RecData ->
         ClosedTerm ->
         Name -> Core (Search ClosedTerm)

getAllEnv : {vars : _} ->
            FC -> (done : List Name) ->
            Env Term vars ->
            List (Term (done ++ vars), Term (done ++ vars))
getAllEnv fc done [] = []
getAllEnv {vars = v :: vs} fc done (b :: env)
   = let rest = getAllEnv fc (done ++ [v]) env
         MkVar p = weakenVar done {inner = v :: vs} First in
         (Local fc Nothing _ p,
           rewrite appendAssociative done [v] vs in
              weakenNs (done ++ [v]) (binderType b)) ::
                   rewrite appendAssociative done [v] vs in rest

-- Search recursively, but only if the given name wasn't solved by unification
searchIfHole : {vars : _} ->
               {auto c : Ref Ctxt Defs} ->
               {auto m : Ref MD Metadata} ->
               {auto u : Ref UST UState} ->
               FC -> SearchOpts -> Maybe RecData -> ClosedTerm ->
               Env Term vars -> ArgInfo vars ->
               Core (Search (Term vars))
searchIfHole fc opts defining topty env arg
    = case depth opts of
           Z => noResult
           S k =>
              do let hole = holeID arg
                 let rig = argRig arg
                 defs <- get Ctxt
                 Just gdef <- lookupCtxtExact (Resolved hole) (gamma defs)
                      | Nothing => noResult
                 let Hole _ _ = definition gdef
                      | _ => one !(normaliseHoles defs env (metaApp arg))
                                -- already solved
                 res <- search fc rig (record { depth = k,
                                                inArg = True } opts)
                               defining topty (Resolved hole)
                 -- When we solve an argument, we're also building a lambda
                 -- expression for its environment, so we need to apply it to
                 -- the current environment to use it as an argument.
                 traverse (\tm => pure !(normaliseHoles defs env
                                         (applyTo fc (embed tm) env))) res

explicit : ArgInfo vars -> Bool
explicit ai
    = case plicit ai of
           Explicit => True
           _ => False

firstSuccess : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               List (Core (Search a)) ->
               Core (Search a)
firstSuccess [] = noResult
firstSuccess (elab :: elabs)
    = do ust <- get UST
         defs <- get Ctxt
         catch (do Result res more <- elab
                      | NoMore => continue ust defs elabs
                   pure (Result res (continue ust defs (more :: elabs))))
               (\err => continue ust defs elabs)
  where
    continue : UState -> Defs -> List (Core (Search a)) ->
               Core (Search a)
    continue ust defs elabs
        = do put UST ust
             put Ctxt defs
             firstSuccess elabs

export
trySearch : {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST UState} ->
            Core (Search a) ->
            Core (Search a) ->
            Core (Search a)
trySearch s1 s2 = firstSuccess [s1, s2]

export
combine : {auto c : Ref Ctxt Defs} ->
          {auto u : Ref UST UState} ->
          (a -> b -> t) -> Search a -> Search b -> Core (Search t)
combine f NoMore y = pure NoMore
combine f (Result x next) NoMore = pure NoMore
combine f (Result x nextx) (Result y nexty)
    = pure $ Result (f x y) $
                     (do nexty' <- nexty
                         combine f !(one x) nexty')
                         `trySearch`
                     ((do nextx' <- nextx
                          combine f nextx' !(one y))
                          `trySearch`
                      (do nextx' <- nextx
                          nexty' <- nexty
                          combine f nextx' nexty'))

mkCandidates : {vars : _} ->
               {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               FC -> Term vars -> List (Search (Term vars)) ->
               Core (Search (Term vars))
-- out of arguments, we have a candidate
mkCandidates fc f [] = one f
-- argument has run out of ideas, we're stuck
mkCandidates fc f (NoMore :: argss) = noResult
-- make a candidate from 'f arg' applied to the rest of the arguments
mkCandidates fc f (Result arg next :: argss)
    = firstSuccess
           [mkCandidates fc (App fc f arg) argss,
            do next' <- next
               mkCandidates fc f (next' :: argss)]

-- Apply the name to arguments and see if the result unifies with the target
-- type, then try to automatically solve any holes which were generated.
-- If there are any remaining holes, search fails.
searchName : {vars : _} ->
             {auto c : Ref Ctxt Defs} ->
             {auto m : Ref MD Metadata} ->
             {auto u : Ref UST UState} ->
             FC -> RigCount -> SearchOpts ->
             Env Term vars -> NF vars -> ClosedTerm ->
             Maybe RecData -> (Name, GlobalDef) -> Core (Search (Term vars))
searchName fc rigc opts env target topty defining (n, ndef)
    = do defs <- get Ctxt
         let True = visibleInAny (!getNS :: !getNestedNS)
                                 (fullname ndef) (visibility ndef)
             | _ => noResult
         let ty = type ndef
         let namety : NameType
                 = case definition ndef of
                        DCon tag arity _ => DataCon tag arity
                        TCon tag arity _ _ _ _ _ _ => TyCon tag arity
                        _ => Func
         log 5 $ "Trying " ++ show (fullname ndef)
         nty <- nf defs env (embed ty)
         (args, appTy) <- mkArgs fc rigc env nty
         logNF 5 "Target" env target
         logNF 10 "App type" env appTy
         ures <- unify inSearch fc env target appTy
         let [] = constraints ures
             | _ => noResult
         -- Search the explicit arguments first, they may resolve other holes
         traverse (searchIfHole fc opts defining topty env)
                  (filter explicit args)
         args' <- traverse (searchIfHole fc opts defining topty env)
                           args
         mkCandidates fc (Ref fc namety n) args'

getSuccessful : {vars : _} ->
                {auto c : Ref Ctxt Defs} ->
                {auto m : Ref MD Metadata} ->
                {auto u : Ref UST UState} ->
                FC -> RigCount -> SearchOpts -> Bool ->
                Env Term vars -> Term vars -> ClosedTerm ->
                Maybe RecData ->
                List (Core (Search (Term vars))) ->
                Core (Search (Term vars))
getSuccessful {vars} fc rig opts mkHole env ty topty defining all
    = do res <- firstSuccess all
         case res of
              NoMore => -- If no successful search, make a hole
                if mkHole && holesOK opts
                   then do defs <- get Ctxt
                           let base = maybe "arg"
                                            (\r => nameRoot (recname r) ++ "_rhs")
                                            defining
                           hn <- uniqueName defs (map nameRoot vars) base
                           (idx, tm) <- newMeta fc rig env (UN hn) ty
                                                (Hole (length env) (holeInit False))
                                                False
                           one tm
                   else noResult
              r => pure r

searchNames : {vars : _} ->
              {auto c : Ref Ctxt Defs} ->
              {auto m : Ref MD Metadata} ->
              {auto u : Ref UST UState} ->
              FC -> RigCount -> SearchOpts -> Env Term vars ->
              Term vars -> ClosedTerm ->
              Maybe RecData -> List Name -> Core (Search (Term vars))
searchNames fc rig opts env ty topty defining []
    = noResult
searchNames fc rig opts env ty topty defining (n :: ns)
    = do defs <- get Ctxt
         vis <- traverse (visible (gamma defs) (currentNS defs :: nestedNS defs)) (n :: ns)
         let visns = mapMaybe id vis
         nfty <- nf defs env ty
         logTerm 10 ("Searching " ++ show (map fst visns) ++ " for ") ty
         getSuccessful fc rig opts False env ty topty defining
            (map (searchName fc rig opts env nfty topty defining) visns)
  where
    visible : Context -> List (List String) -> Name ->
              Core (Maybe (Name, GlobalDef))
    visible gam nspace n
        = do Just def <- lookupCtxtExact n gam
                  | Nothing => pure Nothing
             if visibleInAny nspace n (visibility def)
                then pure (Just (n, def))
                else pure Nothing

tryRecursive : {vars : _} ->
               {auto c : Ref Ctxt Defs} ->
               {auto m : Ref MD Metadata} ->
               {auto u : Ref UST UState} ->
               FC -> RigCount -> SearchOpts ->
               Env Term vars -> Term vars -> ClosedTerm ->
               Maybe RecData -> Core (Search (Term vars))
tryRecursive fc rig opts env ty topty Nothing
    = noResult
tryRecursive fc rig opts env ty topty (Just rdata)
    = do defs <- get Ctxt
         case !(lookupCtxtExact (recname rdata) (gamma defs)) of
              Nothing => noResult
              Just def =>
                do res <- searchName fc rig opts env !(nf defs env ty)
                                     topty Nothing
                                     (recname rdata, def)
                   defs <- get Ctxt
                   filterS (structDiff (lhsapp rdata)) res
  where
    mutual
      -- A fairly simple superficialy syntactic check to make sure that
      -- the recursive call is structurally different from the lhs
      -- (Essentially, meaning that there's a constructor application in
      -- one where there's a local in another, or that constructor applications
      -- differ somewhere)
      argDiff : Term vs -> Term vs' -> Bool
      argDiff (Local _ _ _ _) _ = False
      argDiff (Ref _ _ fn) (Ref _ _ fn') = fn /= fn'
      argDiff (Bind _ _ _ _) _ = False
      argDiff _ (Bind _ _ _ _) = False
      argDiff (App _ f a) (App _ f' a')
         = structDiff f f' || structDiff a a'
      argDiff (PrimVal _ c) (PrimVal _ c') = c /= c'
      argDiff (Erased _ _) _ = False
      argDiff _ (Erased _ _) = False
      argDiff (TType _) (TType _) = False
      argDiff (As _ _ _ x) y = argDiff x y
      argDiff x (As _ _ _ y) = argDiff x y
      argDiff _ _ = True

      appsDiff : Term vs -> Term vs' -> List (Term vs) -> List (Term vs') ->
                 Bool
      appsDiff (Ref _ (DataCon _ _) f) (Ref _ (DataCon _ _) f') args args'
         = f /= f' || anyTrue (zipWith argDiff args args')
      appsDiff (Ref _ (TyCon _ _) f) (Ref _ (TyCon _ _) f') args args'
         = f /= f' || anyTrue (zipWith argDiff args args')
      appsDiff (Ref _ _ f) (Ref _ _ f') args args'
         = f == f'
           && length args == length args'
           && anyTrue (zipWith argDiff args args')
      appsDiff (Ref _ (DataCon _ _) f) (Local _ _ _ _) _ _ = True
      appsDiff (Local _ _ _ _) (Ref _ (DataCon _ _) f) _ _ = True
      appsDiff f f' [] [] = argDiff f f'
      appsDiff _ _ _ _ = False -- can't be sure...

      -- Reject if the recursive call is the same in structure as the lhs
      structDiff : Term vs -> Term vs' -> Bool
      structDiff tm tm'
         = let (f, args) = getFnArgs tm
               (f', args') = getFnArgs tm' in
               appsDiff f f' args args'

-- A local is usable as long as its type isn't a hole
usableLocal : FC -> Env Term vars -> NF vars -> Bool
usableLocal loc env (NApp _ (NMeta _ _ _) args) = False
usableLocal loc _ _ = True

searchLocalWith : {vars : _} ->
                  {auto c : Ref Ctxt Defs} ->
                  {auto m : Ref MD Metadata} ->
                  {auto u : Ref UST UState} ->
                  FC -> RigCount -> SearchOpts -> Env Term vars ->
                  List (Term vars, Term vars) ->
                  Term vars -> ClosedTerm -> Maybe RecData ->
                  Core (Search (Term vars))
searchLocalWith fc rig opts env [] ty topty defining
    = noResult
searchLocalWith {vars} fc rig opts env ((p, pty) :: rest) ty topty defining
    = do defs <- get Ctxt
         nty <- nf defs env ty
         getSuccessful fc rig opts False env ty topty defining
                       [findPos defs p id !(nf defs env pty) nty,
                        searchLocalWith fc rig opts env rest ty
                                        topty defining]
  where
    findDirect : Defs -> Term vars ->
                 (Term vars -> Term vars) ->
                 NF vars -> -- local variable's type
                 NF vars -> -- type we're looking for
                 Core (Search (Term vars))
    findDirect defs prf f nty ty
        = do (args, appTy) <- mkArgs fc rig env nty
             -- We can only use a local variable if it's not an unsolved
             -- hole
             if usableLocal fc env nty
                then
                  tryUnify -- try with no arguments first
                    (do ures <- unify inTerm fc env ty nty
                        let [] = constraints ures
                            | _ => throw (InternalError "Can't use directly")
                        mkCandidates fc (f prf) [])
                    (do ures <- unify inTerm fc env ty appTy
                        let [] = constraints ures
                            | _ => noResult
                        args' <- traverse (searchIfHole fc opts defining topty env)
                                          args
                        mkCandidates fc (f prf) args')
                else noResult

    findPos : Defs -> Term vars ->
              (Term vars -> Term vars) ->
              NF vars -> NF vars -> Core (Search (Term vars))
    findPos defs prf f x@(NTCon pfc pn _ _ [xty, yty]) target
        = getSuccessful fc rig opts False env ty topty defining
              [findDirect defs prf f x target,
                 (do fname <- maybe (throw (InternalError "No fst"))
                                    pure
                                    !fstName
                     sname <- maybe (throw (InternalError "No snd"))
                                    pure
                                    !sndName
                     if !(isPairType pn)
                        then do empty <- clearDefs defs
                                xtytm <- quote empty env xty
                                ytytm <- quote empty env yty
                                getSuccessful fc rig opts False env ty topty defining
                                  [(do xtynf <- evalClosure defs xty
                                       findPos defs prf
                                         (\arg => apply fc (Ref fc Func fname)
                                                          [xtytm,
                                                           ytytm,
                                                           f arg])
                                         xtynf target),
                                   (do ytynf <- evalClosure defs yty
                                       findPos defs prf
                                           (\arg => apply fc (Ref fc Func sname)
                                                          [xtytm,
                                                           ytytm,
                                                           f arg])
                                           ytynf target)]
                         else noResult)]
    findPos defs prf f nty target = findDirect defs prf f nty target

searchLocal : {vars : _} ->
              {auto c : Ref Ctxt Defs} ->
              {auto m : Ref MD Metadata} ->
              {auto u : Ref UST UState} ->
              FC -> RigCount -> SearchOpts ->
              Env Term vars -> Term vars -> ClosedTerm ->
              Maybe RecData -> Core (Search (Term vars))
searchLocal fc rig opts env ty topty defining
    = do defs <- get Ctxt
         -- Reverse the environment so we try the patterns left to right.
         -- This heuristic is just so arguments appear the same order in
         -- recursive calls
         searchLocalWith fc rig opts env (reverse (getAllEnv fc [] env))
                         ty topty defining

searchType : {vars : _} ->
             {auto c : Ref Ctxt Defs} ->
             {auto m : Ref MD Metadata} ->
             {auto u : Ref UST UState} ->
             FC -> RigCount -> SearchOpts -> Env Term vars -> Maybe RecData ->
             ClosedTerm ->
             Nat -> Term vars -> Core (Search (Term vars))
searchType fc rig opts env defining topty (S k) (Bind bfc n (Pi c info ty) sc)
    = do let env' : Env Term (n :: _) = Pi c info ty :: env
         log 10 $ "Introduced lambda, search for " ++ show sc
         scVal <- searchType fc rig opts env' defining topty k sc
         pure (map (Bind bfc n (Lam c info ty)) scVal)
searchType {vars} fc rig opts env defining topty Z (Bind bfc n (Pi c info ty) sc)
    = -- try a local before creating a lambda...
      getSuccessful fc rig opts False env ty topty defining
           [searchLocal fc rig opts env (Bind bfc n (Pi c info ty) sc) topty defining,
            (do defs <- get Ctxt
                let n' = UN !(getArgName defs n vars !(nf defs env ty))
                let env' : Env Term (n' :: _) = Pi c info ty :: env
                let sc' = renameTop n' sc
                log 10 $ "Introduced lambda, search for " ++ show sc'
                scVal <- searchType fc rig opts env' defining topty Z sc'
                pure (map (Bind bfc n' (Lam c info ty)) scVal))]
searchType fc rig opts env defining topty _ ty
    = case getFnArgs ty of
           (Ref rfc (TyCon t ar) n, args) =>
                do defs <- get Ctxt
                   if length args == ar
                     then do sd <- getSearchData fc False n
                             let allHints = concat (map snd (hintGroups sd))
                             -- Solutions is either:
                             -- First try the locals,
                             -- Then try the hints in order
                             -- Then try a recursive call
                             log 10 $ "Hints found for " ++ show n ++ " "
                                         ++ show allHints
                             let tries =
                                   [searchLocal fc rig opts env ty topty defining,
                                    searchNames fc rig opts env ty topty defining allHints]
                             let tryRec =
                                   if recOK opts
                                      then [tryRecursive fc rig opts env ty topty defining]
                                      else []
                             -- if we're in an argument, try the recursive call
                             -- first. We're more likely to want that than nested
                             -- constructors.
                             let allns : List _
                                     = if inArg opts
                                          then tryRec ++ tries
                                          else tries ++ tryRec
                             getSuccessful fc rig opts True env ty topty defining allns
                     else noResult
           _ => do logTerm 10 "Searching locals only at" ty
                   getSuccessful fc rig opts True env ty topty defining
                       ([searchLocal fc rig opts env ty topty defining]
                         ++ if recOK opts
                               then [tryRecursive fc rig opts env ty topty defining]
                               else [])

searchHole : {auto c : Ref Ctxt Defs} ->
             {auto m : Ref MD Metadata} ->
             {auto u : Ref UST UState} ->
             FC -> RigCount -> SearchOpts -> Maybe RecData -> Name ->
             Nat -> ClosedTerm ->
             Defs -> GlobalDef -> Core (Search ClosedTerm)
searchHole fc rig opts defining n locs topty defs glob
    = do searchty <- normalise defs [] (type glob)
         logTerm 10 "Normalised type" searchty
         searchType fc rig opts [] defining topty locs searchty

-- Declared at the top
search fc rig opts defining topty n_in
    = do defs <- get Ctxt
         case !(lookupHoleName n_in (gamma defs)) of
              Just (n, i, gdef) =>
                   -- The definition should be 'BySearch' at this stage,
                   -- if it's arising from an auto implicit
                   case definition gdef of
                        Hole locs _ => searchHole fc rig opts defining n locs topty defs gdef
                        BySearch _ _ _ => searchHole fc rig opts defining n
                                                   !(getArity defs [] (type gdef))
                                                   topty defs gdef
                        _ => do log 10 $ show n_in ++ " not a hole"
                                throw (InternalError $ "Not a hole: " ++ show n ++ " in " ++ show (map recname defining))
              _ => do log 10 $ show n_in ++ " not found"
                      throw (UndefinedName fc n_in)
  where
    lookupHoleName : Name -> Context ->
                     Core (Maybe (Name, Int, GlobalDef))
    lookupHoleName n defs
        = case !(lookupCtxtExactI n defs) of
               Just (i, res) => pure $ Just (n, i, res)
               Nothing => case !(lookupCtxtName n defs) of
                               [res] => pure $ Just res
                               _ => pure Nothing

getLHSData : Defs -> Maybe ClosedTerm -> Core (Maybe RecData)
getLHSData defs Nothing = pure Nothing
getLHSData defs (Just tm) = pure $ getLHS !(normaliseHoles defs [] tm)
  where
    getLHS : Term vars -> Maybe RecData
    getLHS (Bind _ _ (PVar _ _ _) sc) = getLHS sc
    getLHS (Bind _ _ (PLet _ _ _) sc) = getLHS sc
    getLHS sc
        = case getFn sc of
               Ref _ _ n => Just (MkRecData n sc)
               _ => Nothing

firstLinearOK : {auto c : Ref Ctxt Defs} ->
                {auto u : Ref UST UState} ->
                FC -> Search ClosedTerm -> Core (Search ClosedTerm)
firstLinearOK fc NoMore = noResult
firstLinearOK fc (Result t next)
    = tryUnify
            (do linearCheck fc linear False [] t
                pure (Result t (firstLinearOK fc !next)))
            (do next' <- next
                firstLinearOK fc next')

export
exprSearch : {auto c : Ref Ctxt Defs} ->
             {auto m : Ref MD Metadata} ->
             {auto u : Ref UST UState} ->
             FC -> Name -> List Name -> Core (Search ClosedTerm)
exprSearch fc n_in hints
    = do defs <- get Ctxt
         Just (n, idx, gdef) <- lookupHoleName n_in defs
             | Nothing => throw (UndefinedName fc n_in)
         lhs <- findHoleLHS !(getFullName (Resolved idx))
         log 10 $ "LHS hole data " ++ show (n, lhs)
         res <- search fc (multiplicity gdef) (MkSearchOpts False True 5 False)
                       !(getLHSData defs lhs) (type gdef) n
         firstLinearOK fc res
  where
    lookupHoleName : Name -> Defs -> Core (Maybe (Name, Int, GlobalDef))
    lookupHoleName n defs
        = case !(lookupCtxtExactI n (gamma defs)) of
               Just (idx, res) => pure $ Just (n, idx, res)
               Nothing => case !(lookupCtxtName n (gamma defs)) of
                               [res] => pure $ Just res
                               _ => pure Nothing

export
exprSearchN : {auto c : Ref Ctxt Defs} ->
              {auto m : Ref MD Metadata} ->
              {auto u : Ref UST UState} ->
              FC -> Nat -> Name -> List Name -> Core (List ClosedTerm)
exprSearchN fc max n hints
    = searchN max (exprSearch fc n hints)
