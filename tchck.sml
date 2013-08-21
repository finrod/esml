structure ConstrGen :
sig

    datatype 'ed err = VarUndef of CGAst.var * 'ed | TVarUndef of CGAst.tname * 'ed
    val genConstrExpr : PAst.pTerm -> CGAst.cgTerm * CGAst.constr list
    val genConstrDec  : PAst.pDec  -> CGAst.cgDec  * CGAst.constr list
    val genConstrDecs : PAst.pDec list  -> CGAst.cgDec list  * CGAst.constr list
    val genConstrFrom : TAst.env * TAst.typ * PAst.pTerm ->
                        CGAst.cgTerm * CGAst.constr list
    val getErrors : unit -> PAst.pos err list
    val toString : CGAst.pos -> string
end =
struct

  open DTFunctors
  open CGAst
  open PAst
  open Util

  exception NotFound

  val uvcntr = ref 0
  fun newUVar () = 
      let val n = !uvcntr
      in  CTyUVar n
          before uvcntr := n + 1
      end

  val tvcntr = ref 0
  fun newTVar () =
      let val n = !tvcntr
      in  n before tvcntr := n + 1
      end

  datatype 'ed err = VarUndef of var * 'ed | TVarUndef of tname * 'ed
  val errors = ref [] : pos err list ref

  fun flip (x, (y, z)) = (y, (x, z))

  fun tcop bop =
      let val arr  = CTyp o TyArr
          val prod = CTyp o TyProd
          val int  = CTyp TyInt
          val bool = CTyp TyBool
          val bi   = arr (prod (int, int), int)
          val bb   = arr (prod (bool, bool), bool)
          val rel  = arr (prod (int, int), bool)
      in case bop of
             Add => bi
           | Sub => bi
           | Mul => bi
           | Div => bi
           | Mod => bi
           | Neg => arr (int, int)
           | Eq  => rel
           | Lt  => rel
           | Gt  => rel
           | LEq => rel
           | GEq => rel
           | Not => arr (bool, bool)
           | And => bb
           | Or  => bb
      end

  fun kindSynth (D, pos, PTyp (TyArr  (t1, t2))) =
      let val t1' = kindCheck (D, pos, t1, KTyp)
          val t2' = kindCheck (D, pos, t2, KTyp)
      in (CTyp (TyArr  (t1', t2')), KTyp)
      end
    | kindSynth (D, pos, PTyp (TyProd (t1, t2))) =
      let val t1' = kindCheck (D, pos, t1, KTyp)
          val t2' = kindCheck (D, pos, t2, KTyp)
      in (CTyp (TyProd (t1', t2')), KTyp)
      end
    | kindSynth (D, pos, PTyp (TyApp  (t1, t2))) =
      let val (t1', kf) = kindSynth (D, pos, t1)
          val (t2', ka) = kindSynth (D, pos, t2)
          val errstr = "Kind mismatch: " ^ ppty D t1' ^ " : " ^ ppknd kf ^
                       " applied to " ^ ppty D t2' ^ " : " ^ ppknd ka ^ "."
      in case kf of
             KArr (karg, kres) => if karg = ka then (CTyp (TyApp (t1', t2')), KTyp)
                                  else raise Fail errstr
           | _ => raise Fail errstr
      end
    | kindSynth (D, pos, PTyp TyInt)  = (CTyp TyInt, KTyp)
    | kindSynth (D, pos, PTyp TyBool) = (CTyp TyBool, KTyp)
    | kindSynth (D, pos, PTyp (TyVar s)) =
      (case lookup (D, s) of
           SOME (n, k) => (CTyp (TyVar n), k)
         | NONE => (newUVar (), KTyp) before errors := TVarUndef (s, pos) :: !errors)

  and kindCheck (D, pos, pty, k) =
      let val (cty, k') = kindSynth (D, pos, pty)
      in  if k = k' then cty
          else raise Fail ("Kind mismatch in type '" ^ ppty D cty ^ "' : " ^ ppknd k' ^
                           " does not match the expected " ^ ppknd k ^ ".")
      end

  fun ctorCheck (D, tv, CTyp (TyArr (_, t))) = ctorCheck (D, tv, t)
    | ctorCheck (D, tv, CTyp (TyApp (t, _))) = ctorCheck (D, tv, t)
    | ctorCheck (D, tv, CTyp (TyVar tv'))    =
      if tv = tv' then ()
      else raise Fail ("Couldn't match " ^ ppty D (CTyp (TyVar tv)) ^ " against " ^ ppty D (CTyp (TyVar tv')) ^ ".")
    | ctorCheck _ =  raise Fail "Constructor does not end in a variable or type application"

  fun instTy (targs, ty) =
      let val subst = map (fn (_, (tv, _)) => (tv, newUVar ())) targs
          fun aux (CTyp (TyArr  (t1, t2))) = (CTyp (TyArr  (aux t1, aux t2)))
            | aux (CTyp (TyProd (t1, t2))) = (CTyp (TyProd (aux t1, aux t2)))
            | aux (CTyp (TyApp  (t1, t2))) = (CTyp (TyApp  (aux t1, aux t2)))
            | aux (t as CTyp (TyVar tv)) = (case lookup (subst, tv) of
                                                SOME tu => tu
                                              | NONE => t)
            | aux t = t
      in  aux ty
      end

  fun instTyS (CSMono t)  = t
    | instTyS (CSPoly ts) = instTy ts

  fun bindArgs (args, ty) =
      let fun nArr (CTyp (TyArr _)) = false
            | nArr _ = true
          fun aux ([], ty, acc) = if nArr ty then (ty, rev acc)
                                  else raise Fail "Constructor not fully applied"
            | aux (a :: args, CTyp (TyArr (t1, t2)), acc) = aux (args, t2, (a, CSMono t1) :: acc)
            | aux _ = raise Fail "Constructor applied to too many arguments"
      in aux (args, ty, [])
      end

  val toString = Pos.toString

  fun cgExpr (env : CGAst.cgEnv, PT (Var (x, pos)), t, cs) =
      (case lookup (#var env, x) of
           SOME (tyS, _) => (CTerm (Var (x, (pos, t))), CEqc (instTyS tyS, t, pos) :: cs)
         | NONE => raise NotFound)
    | cgExpr (env, PT (Abs (x, e, pos)), t, cs) =
      let val (targ, tres) = (newUVar (), newUVar ())
          val (e', rcs) = cgExpr (updVar (env, (x, (CSMono targ, BVar)) :: #var env), e, tres, cs)
      in  (CTerm (Abs ((x, targ), e', (pos, t))), CEqc (t, CTyp (TyArr (targ, tres)), pos) :: rcs)
      end
    | cgExpr (env, PT (App (e1, e2, pos)), t, cs) =
      let val targ = newUVar ()
          val (e1', cs') = cgExpr (env, e1, (CTyp (TyArr (targ, t))), cs)
          val (e2', rcs) = cgExpr (env, e2, targ, cs')
      in  (CTerm (App (e1', e2', (pos, t))), rcs)
      end
    | cgExpr (env, PT (Pair (e1, e2, pos)), t, cs) =
      let val (tl, tr) = (newUVar (), newUVar ())
          val (e1', cs') = cgExpr (env, e1, tl, cs)
          val (e2', rcs) = cgExpr (env, e2, tr, cs')
      in  (CTerm (Pair (e1', e2', (pos, t))), CEqc (t, CTyp (TyProd (tl, tr)), pos) :: rcs)
      end
    | cgExpr (env, PT (Proj1 (e, pos)), t, cs) =
      let val tr = newUVar ()
          val (e', cs') = cgExpr (env, e, CTyp (TyProd (t, tr)), cs)
      in  (CTerm (Proj1 (e', (pos, t))), cs')
      end
    | cgExpr (env, PT (Proj2 (e, pos)), t, cs) =
      let val tl = newUVar ()
          val (e', cs') = cgExpr (env, e, CTyp (TyProd (tl, t)), cs)
      in  (CTerm (Proj1 (e', (pos, t))), cs')
      end
    | cgExpr (env, PT (IntLit (n, pos)), t, cs) =
      (CTerm (IntLit (n, (pos, t))), CEqc (t, CTyp TyInt, pos) :: cs)
    | cgExpr (env, PT (BoolLit (b, pos)), t, cs) =
      (CTerm (BoolLit (b, (pos, t))), CEqc (t, CTyp TyBool, pos) :: cs)
    | cgExpr (env, PT (Op (bop, pos)), t, cs) =
      (CTerm (Op (bop, (pos, t))), CEqc (tcop bop, t, pos) :: cs)
    | cgExpr (env, PT (Let (ds, e, pos)), t, cs) =
      let val (envL, dsC, cs') = cgDecs (env, ds, cs)
          val (eC, csr) = cgExpr (envL, e, t, cs')
      in  (CTerm (Let (dsC, eC, (pos, t))), csr)
      end
    | cgExpr (env, PT (If (e1, e2, e3, pos)), t, cs) =
      let val (e1', cs1) = cgExpr (env, e1, CTyp TyBool, cs)
          val (e2', cs2) = cgExpr (env, e2, t, cs1)
          val (e3', cs3) = cgExpr (env, e3, t, cs2)
      in  (CTerm (If (e1', e2', e3', (pos, t))), cs3)
      end
    | cgExpr (env, PT (Case (e, alts, pos)), t, cs) =
      let val te = newUVar ()
          val (e', cs1) = cgExpr (env, e, te, cs)
          fun hAlt (((c, args), eb), (ralts, cs)) =
              let val tc = (case lookup (#var env, c) of
                                SOME (tS, Ctor) => instTyS tS
                              | SOME (_,  BVar)   => raise Fail "Not a constructor"
                              | NONE => raise NotFound)
                  val (ft, bds)  = bindArgs (args, tc)
                  val (eb', cs') = cgExpr (updVar (env, List.revAppend (map (fn (x, ts) => (x, (ts, BVar))) bds, #var env)), eb, t, cs)
              in (((c, bds), eb') :: ralts , CEqc (ft, te, pos) :: cs')
              end
          val (ralts, cs2) = foldl hAlt ([], cs1) alts
      in (CTerm (Case (e', rev ralts, (pos, t))), cs2)
      end
    | cgExpr (env, PAnn (e, pt, pos), t, cs) =
      let val at = kindCheck (#ty env, pos, pt, KTyp)
          val (e', cs') = cgExpr (env, e, t, cs)
      in  (e', CEqc (t, at, pos) :: cs')
      end
    | cgExpr (env, PHole pos, t, cs) =
      (CHole (pos, env, t), cs)

  and cgDec (env, PD (Fun defs), cs) =
      let fun hArg (arg, (tas, tr)) =
              let val t = newUVar ()
              in  ((arg, t) :: tas, CTyp (TyArr (t, tr)))
              end
          fun aux (G, [], cs) = (G, [], cs)
            | aux (G, (x, args, e, pos) :: ds, cs) =
              let val tres = newUVar ()
                  val (tas, ty) = foldr hArg ([], tres) args
                  val (GR, ds', cs') = aux ((x, (CSMono ty, BVar)) :: G, ds, cs)
                  val (e', rcs) = cgExpr (updVar (env, List.revAppend (map (fn (x, t) => (x, (CSMono t, BVar))) tas, GR)), e, tres, cs')
              in  (GR, (x, tas, e', (pos, CSMono ty)) :: ds', rcs)
              end
          val (GR, dsr, csr) = aux (#var env, defs, cs)
          val envR = updVar (env, GR)
      in  (envR, CDec (Fun dsr), csr)
      end
    | cgDec (env, PD (PFun defs), cs) =
      let fun hArg (D, pos) ((x, pt), (asC, tr)) =
              let val t = kindCheck (D, pos, pt, KTyp)
              in  ((x, t) :: asC, (CTyp (TyArr (t, tr))))
              end
          fun aux (G, [], cs) = (G, [], cs)
            | aux (G, (x, targs, vargs, tres, e, pos) :: ds, cs) =
              let val targsC = map (fn x => (x, (newTVar (), KTyp))) targs
                  val DC = List.revAppend (targsC, #ty env)
                  val tresC = kindCheck (DC, pos, tres, KTyp)
                  val (vargsC, tyC) = foldr (hArg (DC, pos)) ([], tresC) vargs
                  val (GR, ds', cs') = aux ((x, (CSPoly (targsC, tyC), BVar)) :: G, ds, cs)
                  val (eC, rcs) = cgExpr (mkEnv (DC, List.revAppend (map (fn (x, t) => (x, (CSMono t, BVar))) vargsC, GR)), e, tresC, cs')
              in  (GR, (x, targsC, vargsC, tresC, eC, (pos, CSPoly (targsC, tyC))) :: ds', rcs)
              end
          val (GR, dsr, csr) = aux (#var env, defs, cs)
          val envR = updVar (env, GR)
      in  (envR, CDec (PFun dsr), csr)
      end
    | cgDec (env, PD (Data ds), cs) =
    let (* First, gather the names and kinds of datatypes, and generate tyvars for them *)
        val tyks = map (fn (tn, k, _, _) => (tn, (newTVar (), k))) ds
        val DR = List.revAppend (tyks, #ty env)
        (* Handle a constructor: generate tyvars for polymorphic values,
         * check that the kind works out, and add it to the environment. *)
        fun hCon tv D pos ((v, tns, ty), (cs, G)) =
            let val tvs = map (fn tn => (tn, (newTVar (), KTyp))) tns
                val DC = List.revAppend (tvs, D)
                val tres = kindCheck (DC, pos, ty, KTyp)
                val _ = ctorCheck (DC, tv, tres)
            in ((v, tvs, tres) :: cs, (v, (CSPoly (tvs, tres), Ctor)) :: G)
            end
        (* Handle one (of possibly several mutually recursive) declaration:
         * get the tyvar associated with the type name earlier, handle the constructors
         * and generate the resulting environment. *)
        fun hDec D ((tn, k, cs, pos), (ds, G)) =
            let val tv = valOf (lookup (tyks, tn))
                val (rcs, GR) = foldl (hCon (#1 tv) D pos) ([], G) cs
            in (((tn, tv), k, rev rcs, pos) :: ds, GR)
            end
        val (dsr, GR) = foldl (hDec DR) ([], #var env) ds
    in (mkEnv (DR, GR), CDec (Data (rev dsr)), cs)
    end

  and cgDecs (env, ds, cs) =
      let fun aux ([], env, rds, cs) = (env, rev rds, cs)
            | aux (d :: ds, env, rds, cs) =
              let val (env', d', cs') = cgDec (env, d, cs)
              in  aux (ds, env', d' :: rds, cs')
              end
      in  aux (ds, env, [], cs)
      end

  fun reset () = (tvcntr := 0; uvcntr := 0; errors := [])

  fun genConstrExpr e =
       cgExpr (mkEnv ([], []), e, newUVar (), []) before reset ()

  fun genConstrDec d =
      let val _ = reset ()
          val (_, d, cs) = cgDec (mkEnv ([], []), d, [])
      in (d, cs)
      end

  fun genConstrDecs ds =
      let val _ = reset ()
          val (_, ds, cs) = cgDecs (mkEnv ([], []), ds, [])
      in (ds, cs)
      end

  local
      val revsub = ref [] : (TAst.tvar * cgTyp) list ref

      fun trInstTy t =
          let fun aux (TAst.TyMono k) =
                  (case lookup (!revsub, k) of
                       SOME t => t
                     | NONE => let val t = newUVar ()
                               in t before revsub := (k, t) :: !revsub
                               end)
                | aux (TAst.TyF (TyArr  (t1, t2))) = CTyp (TyArr  (aux t1, aux t2))
                | aux (TAst.TyF (TyProd (t1, t2))) = CTyp (TyProd (aux t1, aux t2))
                | aux (TAst.TyF (TyApp  (t1, t2))) = CTyp (TyApp  (aux t1, aux t2))
                | aux (TAst.TyF (TyVar tv)) = CTyp (TyVar tv)
                | aux (TAst.TyF TyBool)     = CTyp TyBool
                | aux (TAst.TyF TyInt)      = CTyp TyInt
          in aux t
          end

      fun trInstTyS (TAst.SPoly (bs, t)) = CSPoly (map flip bs, trInstTy t)
        | trInstTyS (TAst.SMono t)       = CSMono (trInstTy t)

  in
  fun genConstrFrom ((D, G), t, e) =
      let val DC = map flip D
          val GC = map (fn (x, (ts, d)) => (x, (trInstTyS ts, d))) G
          val tc = trInstTy t
      in cgExpr (mkEnv (DC, GC), e, tc, []) before reset ()
      end
  end

  fun getErrors () = !errors

end

structure CSolver =
struct

  exception NotImplemented
  exception TypeError

  structure UF = IUnionFind

  open CGAst

  datatype 'ed res
    = StructDiff of cgTyp * cgTyp * 'ed
    | Circular   of int   * cgTyp * 'ed

  local
      open Util
      open CGAst
      open DTFunctors
      fun pend x (pend, res) = (x :: pend, res)
      fun res  x (pend, res) = (pend, x :: res)
      val subst = ref [] : (int * cgTyp UF.set) list ref
      fun getSet n = (case lookup (!subst, n) of
                          SOME set => set
                        | NONE => let val set = UF.new (CTyUVar n)
                                  in  set before (subst := (n, set) :: !subst)
                                  end)
      fun reset () = subst := []
  in

  fun force (CTyUVar n) = UF.find (getSet n)
    | force t = t

  fun getSubst () =
      let open TAst
          fun flatten (CTyp (TyArr  (t1, t2))) =
              CTyp (TyArr  (flatten (force t1), flatten (force t2)))
            | flatten (CTyp (TyProd (t1, t2))) =
              CTyp (TyProd (flatten (force t1), flatten (force t2)))
            | flatten (CTyp (TyApp  (t1, t2))) =
              CTyp (TyApp  (flatten (force t1), flatten (force t2)))
            | flatten t = t
      in  map (fn (x, t) => (x, flatten (force (UF.find t)))) (!subst)
      end

  fun occursUVar (CTyUVar m, n) = m = n
    | occursUVar (CTyp (TyArr  (t1, t2)), n) =
      occursUVar (force t1, n) orelse occursUVar (force t2, n)
    | occursUVar (CTyp (TyProd (t1, t2)), n) =
      occursUVar (force t1, n) orelse occursUVar (force t2, n)
    | occursUVar (CTyp (TyApp  (t1, t2)), n) =
      occursUVar (force t1, n) orelse occursUVar (force t2, n)
    | occursUVar (t, n) = false

  fun pickCanon (CTyUVar _, t) = t
    | pickCanon (t, CTyUVar _) = t
    (* at least I think it shouldn't be called, since
       this case is handled outside the union-find *)
    | pickCanon (CTyp t1, CTyp t2) = raise Impossible

  local
      fun getPos (CEqc (_, _, pos)) = pos
  in
  fun fsimpl (TyArr (t1, t2),  TyArr (s1, s2),  c, pr) =
      pend (CEqc (t1, s1, getPos c), c) (pend (CEqc (t2, s2, getPos c), c) pr)
    | fsimpl (TyProd (t1, t2), TyProd (s1, s2), c, pr) =
      pend (CEqc (t1, s1, getPos c), c) (pend (CEqc (t2, s2, getPos c), c) pr)
    | fsimpl (TyApp (t1, t2), TyApp (s1, s2), c, pr) =
      pend (CEqc (t1, s1, getPos c), c) (pend (CEqc (t2, s2, getPos c), c) pr)
    | fsimpl (TyInt,  TyInt,  c, pr) = pr
    | fsimpl (TyBool, TyBool, c, pr) = pr
    | fsimpl (t1 as TyVar n1, t2 as TyVar n2, c, pr) =
      if n1 = n2 then pr else res (StructDiff (CTyp t1, CTyp t2, c)) pr
    | fsimpl (t1, t2, c, pr) = res (StructDiff (CTyp t1, CTyp t2, c)) pr
  end

  fun csimpl (CTyUVar n, CTyUVar m, c, pr) =
      pr before UF.union pickCanon (getSet n) (getSet m)
    | csimpl (t1 as CTyUVar n, t2, c, pr) =
      if occursUVar (t2, n) then res (Circular (n, t2, c)) pr
      else (pr before UF.union pickCanon (getSet n) (UF.new t2))
    | csimpl (t1, t2 as CTyUVar n, c, pr) =
      if occursUVar (t1, n) then res (Circular (n, t1, c)) pr
      else (pr before UF.union pickCanon (UF.new t1) (getSet n))
    | csimpl (CTyp t1, CTyp t2, c, pr) =
      fsimpl (t1, t2, c, pr)

  fun simplify constrs =
      let fun aux ([], res) = res
            | aux ((CEqc (t1, t2, pos), r) :: pend, res) = aux (csimpl (force t1, force t2, r, (pend, res)))
      in (reset (); aux (constrs, []))
      end

  end

end

structure TypeChecker =
struct

  open CGAst
  open TAst
  open DTFunctors
  open Util

  fun substC (s, CTyp (TyArr  (t1, t2))) = CTyp (TyArr  (substC (s, t1), substC (s, t2)))
    | substC (s, CTyp (TyProd (t1, t2))) = CTyp (TyProd (substC (s, t1), substC (s, t2)))
    | substC (s, CTyp (TyApp  (t1, t2))) = CTyp (TyApp  (substC (s, t1), substC (s, t2)))
    | substC (s, t as CTyp _) = t
    | substC (s, t as CTyUVar n) = (case lookup (s, n) of
                                       SOME tr => tr
                                     | NONE => t)

  local
      val monocntr = ref 0
      val monoSub = ref [] : (int * int) list ref
      fun newMono () = let val n = !monocntr in n before monocntr := n + 1 end
      fun flip (x, (y, z)) = (y, (x, z))
  in

  fun mkMono (CTyp (TyArr  (t1, t2))) =
      TyF (TyArr  (mkMono t1, mkMono t2))
    | mkMono (CTyp (TyProd (t1, t2))) =
      TyF (TyProd (mkMono t1, mkMono t2))
    | mkMono (CTyp (TyApp  (t1, t2))) =
      TyF (TyApp  (mkMono t1, mkMono t2))
    | mkMono (CTyp TyInt)  = TyF TyInt
    | mkMono (CTyp TyBool) = TyF TyBool
    | mkMono (CTyp (TyVar a)) = TyF (TyVar a)
    | mkMono (CTyUVar n) =
      (case lookup (!monoSub, n) of
           SOME k => TyMono k
         | NONE => let val k = newMono ()
                   in TyMono k before monoSub := (n, k) :: !monoSub
                   end)

  fun subst (s, CTyp (TyArr  (t1, t2))) =
      TyF (TyArr  (subst (s, t1), subst (s, t2)))
    | subst (s, CTyp (TyProd (t1, t2))) = 
      TyF (TyProd (subst (s, t1), subst (s, t2)))
    | subst (s, CTyp (TyApp (t1, t2))) = 
      TyF (TyApp (subst (s, t1), subst (s, t2)))
    | subst (s, CTyp TyInt)  = TyF TyInt
    | subst (s, CTyp TyBool) = TyF TyBool
    | subst (s, CTyp (TyVar a)) = TyF (TyVar a)
    | subst (s, t as CTyUVar n) =
      (case lookup (s, n) of
           SOME tr => mkMono tr
         | NONE => mkMono t)

  fun substS (s, CSPoly (tvs, ty)) = SPoly (map flip tvs, subst (s, ty))
    | substS (s, CSMono ty) = SMono (subst (s, ty))

  fun trExpr (sub, CTerm (Var (x, (pos, ty)))) =
      TmF (Var (x, (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (Abs ((x, targ), e, (pos, ty)))) =
      TmF (Abs ((x, subst (sub, targ)), trExpr (sub, e), (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (App (e1, e2, (pos, ty)))) =
      TmF (App (trExpr (sub, e1), trExpr (sub, e2), (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (Pair (e1, e2, (pos, ty)))) =
      TmF (Pair (trExpr (sub, e1), trExpr (sub, e2), (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (Proj1 (e, (pos, ty)))) =
      TmF (Proj1 (trExpr (sub, e), (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (Proj2 (e, (pos, ty)))) =
      TmF (Proj2 (trExpr (sub, e), (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (IntLit  (n, (pos, ty)))) =
      TmF (IntLit  (n, (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (BoolLit (n, (pos, ty)))) =
      TmF (BoolLit (n, (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (Op (bop, (pos, ty)))) =
      TmF (Op (bop, (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (Let (ds, e, (pos, ty)))) =
      TmF (Let (trDecs (sub, ds), trExpr (sub, e), (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (If (e1, e2, e3, (pos, ty)))) =
      TmF (If (trExpr (sub, e1), trExpr (sub, e2), trExpr (sub, e3), (pos, subst (sub, ty))))
    | trExpr (sub, CTerm (Case (e, alts, (pos, ty)))) =
      TmF (Case (trExpr (sub, e), map (fn a => trAlt (sub, a)) alts, (pos, subst (sub, ty))))
    | trExpr (sub, CHole (pos, env, t)) =
      (* This'll probably have to become smarter *)
      let val ntys = (map flip (#ty env),
                      map (fn (x, (tys, d)) => (x, (substS (sub, tys), d))) (#var env),
                      subst (sub, t))
      in  THole (ref (Open (pos, ntys, (env, t))))
      end

  and trAlt (sub, ((c, bds), expr)) =
      ((c, map (fn (v, ts) => (v, substS (sub, ts))) bds), trExpr (sub, expr))

  and trDec (sub, CDec (Fun  ds)) =
      DF (Fun (map (fn (x, args, e, (pos, tyS)) =>
                       (x, map (fn (x, ty) => (x, subst (sub, ty))) args,
                        trExpr (sub, e), (pos, substS (sub, tyS)))) ds))
    | trDec (sub, CDec (PFun ds)) =
      DF (PFun (map (fn (x, targs, args, ty, e, (pos, tyS)) =>
                        (x, map flip targs, map (fn (x, ty) => (x, subst (sub, ty))) args,
                         subst (sub, ty), trExpr (sub, e), (pos, substS (sub, tyS)))) ds))
    | trDec (sub, CDec (Data ds)) =
      DF (Data (map (fn ((tn, (tv, k')), k, cs, ann) =>
                        ((tv, (tn, k')), k,
                         map (fn (x, tvs, ty) => (x, map (fn (tn, (tv, k)) =>
                                                             (tv, (tn, k))) tvs,
                                                  subst (sub, ty))) cs, ann)) ds))

  and trDecs (sub, ds) = map (fn d => trDec (sub, d)) ds

  end      

  local
      fun merge ([], xs) = xs
        | merge (xs, []) = xs
        | merge (x :: xs, y :: ys) = if x <= y then x :: merge (xs, y :: ys) else y :: merge (x :: xs, ys)
  in

  fun getMonos (TyF (TyArr  (t1, t2))) = merge (getMonos t1, getMonos t2)
    | getMonos (TyF (TyProd (t1, t2))) = merge (getMonos t1, getMonos t2)
    | getMonos (TyF (TyApp  (t1, t2))) = merge (getMonos t1, getMonos t2)
    | getMonos (TyF t) = []
    | getMonos (TyMono n) = [n]

  end

  fun monErrs (DF d) =
      let fun fout xs = List.filter (fn (ms, _, _) => not (null ms)) xs
          fun gMS (SPoly (xs, ty)) = getMonos ty
            | gMS (SMono ty) = getMonos ty
          fun gMon (Fun ds) = List.map (fn (_, _, _, (pos, tyS)) => (gMS tyS, tyS, pos)) ds
            | gMon (PFun ds) = List.map (fn (_, _, _, _, _, (pos, tyS)) => (gMS tyS, tyS, pos)) ds
            | gMon (Data _) = []
      in fout (gMon d)
      end

  datatype error = EVarUndefined  of var * pos
                 | ETVarUndefined of tname * pos
                 | ECircularDep   of int * cgTyp * cgTyp * cgTyp * pos
                 | EStructDiff    of cgTyp * cgTyp * cgTyp * cgTyp * pos
                 | EEscapedMonos  of int list * tyS * pos

  fun reportMS xs = Sum.INL (map EEscapedMonos xs)

  fun reportErrors (cgErrs, tyErrs, subst) =
      let open ConstrGen
          open CSolver
          fun docg (VarUndef  (x, pos)) = EVarUndefined  (x, pos)
            | docg (TVarUndef (a, pos)) = ETVarUndefined (a, pos)
          fun dotc s (StructDiff (t1, t2, CEqc (st1, st2, pos))) =
              EStructDiff (substC (s, t1), substC (s, t2), substC (s, st1), substC (s, st2), pos)
            | dotc s (Circular (n, t, CEqc (st1, st2, pos))) =
              ECircularDep (n, t, substC (s, st1), substC (s, st2), pos)
      in Sum.INL (map docg cgErrs @ map (dotc subst) tyErrs)
      end

  fun tcExpr e =
      let val (e', cs) = ConstrGen.genConstrExpr e
          val cgErrs   = ConstrGen.getErrors ()
          val residual = CSolver.simplify (map (fn x => (x, x)) cs)
          val sub      = CSolver.getSubst ()
      in if null cgErrs andalso null residual
         then let val e'' = trExpr (sub, e')
                  val (pos, ty) = TAst.annE e''
                  val ms = getMonos ty
              in if null ms then Sum.INR e''
                 else reportMS [(ms, SMono ty, pos)]
              end
         else reportErrors (cgErrs, residual, sub)
      end

  fun tcDec d =
      let val (d', cs) = ConstrGen.genConstrDec d
          val cgErrs   = ConstrGen.getErrors ()
          val residual = CSolver.simplify (map (fn x => (x, x)) cs)
          val sub      = CSolver.getSubst ()
      in if null cgErrs andalso null residual
         then let val d''  = trDec (sub, d')
                  val errs = monErrs d''
              in if null errs then Sum.INR d''
                 else reportMS errs
              end
         else reportErrors (cgErrs, residual, sub)
      end

  fun tcDecs ds =
      let val (ds', cs) = ConstrGen.genConstrDecs ds
          val cgErrs   = ConstrGen.getErrors ()
          val residual = CSolver.simplify (map (fn x => (x, x)) cs)
          val sub      = CSolver.getSubst ()
      in if null cgErrs andalso null residual
         then let val ds'' = trDecs (sub, ds')
                  val errs = List.concat (map monErrs ds'')
              in if null errs then Sum.INR ds''
                 else reportMS errs
              end
         else reportErrors (cgErrs, residual, sub)
      end

  fun refineExpr (env, t, e) =
      let val (e', cs) = ConstrGen.genConstrFrom (env, t, e)
          val cgErrs   = ConstrGen.getErrors ()
          val residual = CSolver.simplify (map (fn x => (x, x)) cs)
          val sub      = CSolver.getSubst ()
      in if null cgErrs andalso null residual
         then let val e'' = trExpr (sub, e')
                  val (pos, ty) = TAst.annE e''
                  val ms = getMonos ty
              in if null ms then Sum.INR e''
                 else reportMS [(ms, SMono ty, pos)]
              end
         else reportErrors (cgErrs, residual, sub)
      end
      
end
