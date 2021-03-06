
structure DTFunctors =
struct

  datatype kind = KTyp | KArr of kind * kind
  datatype bdesc = Ctor | BVar
  datatype ('var, 'typ) tbdesc = DPoly | DData of kind * 'var list | DTypeDef of kind * 'typ

  datatype ('tvar, 'typ) typF
    = TyArr  of 'typ * 'typ
    | TyProd of 'typ * 'typ
    | TyApp  of 'typ * 'typ
    | TyInt | TyBool
    | TyVar  of 'tvar

  datatype btinop = Add | Sub | Mul | Div | Mod | Neg | Eq | Lt | Gt
                  | LEq | GEq | Not | And | Or

  datatype ('var, 'arg, 'alt, 'dec, 'term, 'ann) termF
    = Var of 'var * 'ann
    | Abs of 'arg * 'term * 'ann
    | App of 'term * 'term * 'ann
    | Pair of 'term * 'term * 'ann
    | Proj1 of 'term * 'ann
    | Proj2 of 'term * 'ann
    | IntLit of int * 'ann
    | BoolLit of bool * 'ann
    | Op of btinop * 'ann
    | Let of 'dec list * 'term * 'ann
    | If of 'term * 'term * 'term * 'ann
    | Case of 'term * 'alt list * 'ann

  datatype ('var, 'arg, 'tvar, 'typ, 'term, 'eann, 'tann) decF
    = Fun of ('var * 'arg list * 'term * 'eann) list
    | PFun of ('var * 'tvar list * ('var * 'typ) list * 'typ * 'term * 'eann) list
    | Data of ('tvar * kind * ('var * 'tvar list * 'typ) list * 'tann) list
    | Type of ('tvar * 'typ * 'tann)

  fun annE (Var (x, a)) = a
    | annE (Abs (arg, e, a)) = a
    | annE (App (e1, e2, a)) = a
    | annE (Pair (e1, e2, a)) = a
    | annE (Proj1 (e, a)) = a
    | annE (Proj2 (e, a)) = a
    | annE (IntLit (n, a)) = a
    | annE (BoolLit (b, a)) = a
    | annE (Op (bop, a)) = a
    | annE (Let (ds, e, a)) = a
    | annE (If (e1, e2, e3, a)) = a
    | annE (Case (e, alts, a)) = a

  local fun parens s = "(" ^ s ^ ")"
  in

  fun ppknd k =
      let fun aux KTyp = "*"
            | aux (KArr (k1, k2)) = "(" ^ aux k1 ^ " -> " ^ ppknd k2 ^ ")"
      in case k of
             KTyp => "*"
           | KArr (k1, k2) => aux k1 ^ " -> " ^ ppknd k2
      end

  fun ppty f g n (TyArr  (t1, t2)) =
      let val r = f 2 t1 ^ " -> " ^ f 1 t2
      in if n > 1 then parens r else r
      end
    | ppty f g n (TyProd (t1, t2)) =
      let val r = f 2 t1 ^ " * " ^ f 2 t2
      in if n > 2 then parens r else r
      end
    | ppty f g n (TyApp  (t1, t2)) =
      let val r = f 3 t1 ^ " " ^ f 3 t2
      in if n > 3 then parens r else r
      end
    | ppty f g n TyInt  = "int"
    | ppty f g n TyBool = "bool"
    | ppty f g n (TyVar a) = g a

  type ('alt, 'arg, 'dec, 'term, 'var) pprecE =
       {alt: 'alt -> string, arg: 'arg -> string, dec: 'dec -> string,
        term: int -> 'term -> string, var: 'var -> string}
  type ('arg, 'targ, 'term, 'typ, 'var) pprecD =
       {arg: 'arg -> string, targ: 'targ -> string, term: 'term -> string,
        typ: 'typ -> string, var: 'var -> string}

  fun ppexp (fs : ('alt, 'arg, 'dec, 'term, 'var) pprecE) n (Var (v, _)) = #var fs v
    | ppexp fs n (Abs (a, t, _)) =
      let val s = "fn " ^ #arg fs a ^ " => " ^ #term fs 0 t
      in if n > 0 then parens s else s
      end
    | ppexp fs n (App (t1, t2, _)) =
      let val s = #term fs 1 t1 ^ " " ^ #term fs 2 t2
      in if n > 1 then parens s else s
      end
    | ppexp fs n (Pair (t1, t2, _)) = parens (#term fs 0 t1 ^ ", " ^ #term fs 0 t2)
    | ppexp fs n (Proj1 (t, _)) = "fst " ^ #term fs 1 t
    | ppexp fs n (Proj2 (t, _)) = "snd " ^ #term fs 1 t
    | ppexp fs _ (IntLit (n, _)) = Int.toString n
    | ppexp fs n (BoolLit (b, _)) = if b then "true" else "false"
    | ppexp fs n (Op (b, _)) = raise Fail "Not implemented"
    | ppexp fs n (Let (ds, t, _)) = "let\n" ^ concat (map (#dec fs) ds) ^ "in " ^ #term fs 0 t ^ "\nend"
    | ppexp fs n (If (t1, t2, t3, _)) =
      let val s = "if " ^ #term fs 0 t1 ^ " then " ^ #term fs 0 t2 ^ "else" ^ #term fs 0 t3
      in if n > 0 then parens s else s
      end
    | ppexp fs n (Case (t, alts, _)) = "case " ^ #term fs 0 t ^ " of\n" ^ String.concatWith "| " (map (#alt fs) alts) ^ "end"

  fun ppdec (fs : ('arg, 'targ, 'term, 'typ, 'var) pprecD) (Fun ds) = "fun " ^ String.concatWith "and "
            (map (fn (v, args, t, _) => #var fs v ^ " " ^ String.concatWith " " (map (#arg fs) args)
                                   ^ " = " ^ #term fs t) ds)
    | ppdec fs (PFun ds) = "fun " ^ String.concatWith "and "
            (map (fn (v, targs, args, ty, t, _) => #var fs v ^ " [" ^ String.concatWith " " (map (#targ fs) targs)
                 ^ "] " ^ String.concatWith " " (map (fn (v, ty) => parens (#var fs v ^ " : " ^ #typ fs ty)) args)
                 ^ " : " ^ #typ fs ty ^ " = " ^ #term fs t) ds)
    | ppdec fs (Data ds) = raise Fail "Not implemented"

  end

  fun kindOf DPoly = KTyp
    | kindOf (DData (k, _)) = k
    | kindOf (DTypeDef (k, _)) = k

end

structure PAst =
struct

  local open DTFunctors in

  datatype pTyp = PTyp of (string, pTyp) typF

  type var = string
  type pos = Pos.pos

  type pPat = var * var list

  (* FIXME: once stuff typechecks, uncomment the optional typing of arguments *)
  datatype pTerm = PT of (var, var (* * pTyp option *), pAlt, pDec, pTerm, pos) termF
                 | PHole of pos | PAnn of pTerm * pTyp * pos
       and pDec  = PD of (var, var (* * pTyp option *), string, pTyp, pTerm, pos, pos) decF
                                                                                       
  withtype pAlt = pPat * pTerm


  end

  fun annE (PT t) = DTFunctors.annE t
    | annE (PAnn (_, _, p)) = p
    | annE (PHole p) = p

end

structure CGAst =
struct

  local open DTFunctors in

  type var = string
  type pos = Pos.pos
  type tvar = int
  type tname = string

  datatype cgTyp = CTyUVar of int | CTyp of (tvar, cgTyp) typF
  datatype cgTyS = CSPoly of (tname * tvar) list * cgTyp | CSMono of cgTyp
  type cgContext  = (var * (cgTyS * bdesc)) list
  type cgTContext = (tname * (tvar * (var, cgTyp) tbdesc)) list
  type cgEnv      = cgTContext * cgContext

  type cgPat  = var * (var * cgTyS) list

  datatype cgTerm = CTerm of (var, var * cgTyp, cgAlt, cgDec, cgTerm, pos * cgTyp) termF
                  | CHole of pos * cgEnv * cgTyp
       and cgDec  = CDec  of (var, var * cgTyp, tname * tvar, cgTyp, cgTerm, pos * cgTyS, pos * kind * (var * cgTyS) list) decF
  withtype cgAlt  = cgPat * cgTerm

  fun stripTC D = map (fn (tn, (tv, _)) => (tv, tn)) D

  fun ppuvar n = "?X" ^ Int.toString n
  fun ppty D ty =
      let fun pptyvar D n = (case Util.lookup (D, n) of
                                 SOME s => s
                               | NONE => "?V" ^ Int.toString n)
          fun aux _ (CTyUVar n) = ppuvar n
            | aux n (CTyp t) = DTFunctors.ppty aux (pptyvar D) n t
      in aux 1 ty
      end
  fun pptys (D, CSMono t) = ppty D t
    | pptys (D, CSPoly (s, t)) = 
      let val ctx = map (fn (tn, tv) => (tv, tn)) s @ D
          val tc = "[" ^ String.concatWith " " (map #1 s) ^ "] "
      in tc ^ ppty ctx t
      end
  end

end

structure TAst =
struct

  local open DTFunctors in

  type tvar = int
  type tname = string
  type var = string
  type pos = Pos.pos

  datatype typ = TyF of (tvar, typ) typF | TyMono of tvar
  datatype tyS = SPoly of (tvar * tname) list * typ | SMono of typ
  type tycontext = (tvar * (tname * (var, typ) tbdesc)) list
  type context   = (var * (tyS * bdesc)) list
  type env       = tycontext * context

  type pattern  = var * (var * tyS) list

  datatype hole = Open of env * (CGAst.cgEnv * CGAst.cgTyp) * (pos * typ) | Closed of term
       and term = TmF of (var, var * typ, alt, dec, term, pos * typ) termF
                | THole of hole ref
       and dec  = DF of (var, var * typ, tvar * tname, typ, term,  pos * tyS, pos * kind * (var * tyS) list) decF
  withtype alt  = pattern * term

  fun extWith ((D, G), DF (Fun  ds)) = (D, foldl (fn (fd, G) => (#1 fd, (#2 (#4 fd), BVar)) :: G) G ds)
    | extWith ((D, G), DF (PFun ds)) = (D, foldl (fn (fd, G) => (#1 fd, (#2 (#6 fd), BVar)) :: G) G ds)
    | extWith (E,      DF (Data dt)) =
      let fun hData (((tv, tn), _, _, (_, k, cts)), (D, G)) =
              ((tv, (tn, DData (k, map #1 cts))) :: D, foldl (fn ((x, tS), G) => (x, (tS, Ctor)) :: G) G cts)
      in  foldl hData E dt
      end
    | extWith ((D, G), DF (Type ((tv, tn), t, (_, k, _))))  = ((tv, (tn, DTypeDef (k, t))) :: D, G)

  fun annE (TmF t) = DTFunctors.annE t
    | annE (THole hr) = (case !hr of
                             Open (_, _, pt) => pt
                           | Closed t => annE t)

  fun stripTC D = map (fn (tv, (tn, _)) => (tv, tn)) D

  fun ppty (D, ty) =
      let fun pptyvar n = (case Util.lookup (D, n) of
                               SOME s => s
                             | NONE => "?V" ^ Int.toString n)
          fun aux _ (TyMono n) = "_t" ^ Int.toString n
            | aux n (TyF t) = DTFunctors.ppty aux pptyvar n t
      in aux 1 ty
      end

  fun pptys (D, SMono t) = ppty (D, t)
    | pptys (D, SPoly (s, t)) =
      let val ctx = s @ D
          val tc = "[" ^ String.concatWith " " (map #2 s) ^ "] "
      in tc ^ ppty (ctx, t)
      end

  end

  fun ppexp D n (TmF t) = DTFunctors.ppexp {var = fn x => x, arg = fn (v, t) => v, alt = ppalt D,
                                            term = ppexp D, dec = ppdec D} n t
    | ppexp D n (THole hr) = "#{ }"
  and ppdec D (DF d) = DTFunctors.ppdec {var = fn x => x, typ = fn t => ppty (D, t), targ = fn (x, y) => y,
                                         term = ppexp D 0, arg = fn (v, t) => v} d
  and ppalt D ((v, vs), t) = v ^ " " ^ String.concatWith " " (map (fn (x, _) => x) vs) ^ " => " ^ ppexp D 0 t ^ "\n"

  local
      fun flip (x, (y, z)) = (y, (x, z))
      open DTFunctors
      open CGAst
  in
  fun trTypNM (TyMono k) = raise Util.Impossible
    | trTypNM (TyF (TyArr  (t1, t2))) = CTyp (TyArr  (trTypNM t1, trTypNM t2))
    | trTypNM (TyF (TyProd (t1, t2))) = CTyp (TyProd (trTypNM t1, trTypNM t2))
    | trTypNM (TyF (TyApp  (t1, t2))) = CTyp (TyApp  (trTypNM t1, trTypNM t2))
    | trTypNM (TyF (TyVar tv)) = CTyp (TyVar tv)
    | trTypNM (TyF TyBool)     = CTyp TyBool
    | trTypNM (TyF TyInt)      = CTyp TyInt
  fun trTySNM (SPoly (bs, t)) = CSPoly (map (fn (x, y) => (y, x)) bs, trTypNM t)
    | trTySNM (SMono t)       = CSMono (trTypNM t)
  end

end

structure Constr =
struct

  local
      open TAst
      open CGAst
  in

  datatype constr = CEqc of (tycontext * cgTContext) * cgTyp * cgTyp * pos

  fun ppconstr (CEqc ((GD, LD), t1, t2, pos)) =
      let val pc = map (fn (tn, (tv, _)) => (tv, tn)) LD @ map (fn (tv, (tn, _)) => (tv, tn)) GD
      in ppty pc t1 ^ " ~ " ^ ppty pc t2 ^ " @ " ^ Pos.toString pos ^ "\n"
      end

  end

end
