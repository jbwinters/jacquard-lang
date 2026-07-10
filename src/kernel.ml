(** Kernel grammar (spec §4): the checker over generic triples and the typed OCaml mirror.

    Layer 1 is [Form.t] (any triple); layer 2 is this module: a triple that converts is a kernel
    form, one that does not is just data. [of_form]/[decl_of_form]/[expr_of_form] validate and build
    the typed AST; [to_form] is the injective inverse, preserving whatever meta the AST holds.

    Triple encodings, pinned (bootstrap notation in parens; `(...)` groups are [Form.t] values with
    the reserved head ["group"]):

    - expr: [(lit 1)], [(var x)], [(ref #h term|con|op)], [(lam (pat ..) body)], [(app fn arg ..)],
      [(let rec|nonrec pat value body)], [(match scrutinee clause+)], [(tuple expr ..)],
      [(handle body ret opclause ..)], [(quote form)], [(unquote expr)], [(ann expr ty)]
    - pat: [(pwild)], [(pvar x)], [(plit 1)], [(pcon ref pat ..)], [(ptuple pat ..)], [(pas x pat)]
    - ty: [(tref ref)], [(tvar a)], [(tapp head arg+)], [(tarrow (ty ..) row ty)], [(ttuple ty ..)],
      [(tforall ((tvar a) ..) ((rvar e) ..) ty)]
    - decl: [(defterm (binding+))], [(deftype name ((tvar a) ..) conspec+)],
      [(defeffect name ((tvar a) ..) opspec+)]
    - auxiliaries: [(clause pat expr)], [(ret pat expr)], [(opclause op (pat ..) resume-name body)],
      [(binding name (ty?) value)], [(con name field ..)], [(field label? ty)],
      [(op name (ty ..) result)], [(row (eref e) .. var?)], [(eref ref)], [(rvar e)]

    References that are names before resolution and hashes after ([gref]) accept either a symbol or
    a [#hash] argument. [Quote] payloads stay raw [Form.t] data (spec §5.1: quoted code is the
    triple before name resolution); the validator only checks that every LIVE [(unquote e)] splices
    a valid expression. Liveness follows conventional quasiquote nesting: a nested [quote] raises
    the level, an [unquote] lowers it, and only level-0 unquotes are live — an unquote under a
    nested quote is data belonging to the inner quote. Resolution and hashing apply the same rule.

    Structural rules enforced here, each with its own code: [Unquote] only under [Quote] (E0204);
    [Lam] params (E0205) and [Let] binders (E0206) irrefutable; [Let rec] binder a variable (E0207)
    with a [Lam] value (E0208); [Match] nonempty (E0209); [Handle] exactly one [ret] clause (E0212).
    Shape errors use E0201 (unknown head), E0202 (wrong arity), E0203 (wrong argument sort), E0210
    (bad ref kind), E0211 (bad rec flag). *)

type gref = Named of string | Hashed of Hash.t
type refkind = Term | Con | Op
type lit = LInt of int | LReal of float | LText of string
type 'a node = { it : 'a; meta : Meta.t }

type expr = expr_node node

and expr_node =
  | Lit of lit
  | Var of string
  | Ref of Hash.t * refkind
  | Lam of pat list * expr
  | App of expr * expr list
  | Let of { isrec : bool; binder : pat; value : expr; body : expr }
  | Match of expr * clause list
  | Tuple of expr list
  | Handle of { body : expr; ret : ret; ops : opclause list }
  | Quote of Form.t
  | Unquote of expr
  | Ann of expr * ty
  | GroupRef of int
      (** Internal marker, not one of the 27 kernel forms: a resolved reference to the [i]-th member
          (source order) of the enclosing [DefTerm] group (spec §6). Produced by resolution,
          consumed by canonicalization; encoded as [(groupref i)] so canonical printed declarations
          survive a store round-trip. *)

and clause = { cpat : pat; cbody : expr; cmeta : Meta.t }
and ret = { rbinder : pat; rbody : expr; rmeta : Meta.t }
and opclause = { op : gref; params : pat list; resume : string; obody : expr; ometa : Meta.t }
and pat = pat_node node

and pat_node =
  | PWild
  | PVar of string
  | PLit of lit
  | PCon of gref * pat list
  | PTuple of pat list
  | PAs of string * pat

and ty = ty_node node

and ty_node =
  | TRef of gref
  | TVar of string
  | TApp of ty * ty list
  | TArrow of ty list * row * ty
  | TTuple of ty list
  | TForall of string list * string list * ty

and row = { effects : gref list; rvar : string option; wmeta : Meta.t }

type binding = { bname : string; annot : ty option; value : expr; bmeta : Meta.t }

type conspec = { con_name : string; fields : field list; kmeta : Meta.t }
and field = { label : string option; fty : ty; fmeta : Meta.t }

type opspec = { op_name : string; op_params : ty list; op_result : ty; smeta : Meta.t }

type decl = decl_node node

and decl_node =
  | DefTerm of binding list
  | DefType of { tname : string; tvars : string list; cons : conspec list }
  | DefEffect of { ename : string; evars : string list; ops : opspec list }

(** A corpus file is a sequence of declarations and bare expressions. *)
type top = Decl of decl | Expr of expr

(* ------------------------------------------------------------------ *)
(* Validation: forms to typed AST.                                     *)
(* ------------------------------------------------------------------ *)

(* Internal control flow only; never escapes this module. *)
exception Err of Diag.t

let err ?meta ~code fmt =
  Printf.ksprintf
    (fun msg -> raise (Err (Diag.error ?span:(Option.bind meta Meta.span) ~code msg)))
    fmt

let expect_arity (f : Form.t) n =
  if List.length f.Form.args <> n then
    err ~meta:f.Form.meta ~code:"E0202" "`%s` expects %d argument(s), got %d" f.Form.head n
      (List.length f.Form.args)

let expect_min_arity (f : Form.t) n =
  if List.length f.Form.args < n then
    err ~meta:f.Form.meta ~code:"E0202" "`%s` expects at least %d argument(s), got %d" f.Form.head n
      (List.length f.Form.args)

let the_form ~what (parent : Form.t) = function
  | Form.F f -> f
  | _ -> err ~meta:parent.Form.meta ~code:"E0203" "%s in `%s` must be a form" what parent.Form.head

let the_sym ~what (parent : Form.t) = function
  | Form.Sym s -> s
  | _ ->
      err ~meta:parent.Form.meta ~code:"E0203" "%s in `%s` must be a symbol" what parent.Form.head

let the_gref ~what (parent : Form.t) = function
  | Form.Sym s -> Named s
  | Form.Hash h -> Hashed h
  | _ ->
      err ~meta:parent.Form.meta ~code:"E0203" "%s in `%s` must be a symbol or a #hash" what
        parent.Form.head

let the_lit ~what (parent : Form.t) = function
  | Form.Int i -> LInt i
  | Form.Real r -> LReal r
  | Form.Text s -> LText s
  | _ ->
      err ~meta:parent.Form.meta ~code:"E0203"
        "%s in `%s` must be an integer, real, or text literal" what parent.Form.head

(* A `( ... )` group; [what] names the position for diagnostics. *)
let the_group ~what (parent : Form.t) arg =
  let f = the_form ~what parent arg in
  if f.Form.head <> "group" then
    err ~meta:f.Form.meta ~code:"E0203" "%s in `%s` must be a parenthesized group" what
      parent.Form.head;
  List.map (the_form ~what:"group element" f) f.Form.args

let is_irrefutable (p : pat) =
  let rec go p =
    match p.it with
    | PWild | PVar _ -> true
    | PTuple ps -> List.for_all go ps
    | PAs (_, inner) -> go inner
    | PLit _ | PCon _ -> false
  in
  go p

let rec expr_of (f : Form.t) : expr =
  let node it = { it; meta = f.Form.meta } in
  match f.Form.head with
  | "lit" ->
      expect_arity f 1;
      node (Lit (the_lit ~what:"the literal" f (List.nth f.Form.args 0)))
  | "var" ->
      expect_arity f 1;
      node (Var (the_sym ~what:"the variable name" f (List.nth f.Form.args 0)))
  | "ref" -> (
      expect_arity f 2;
      let h =
        match List.nth f.Form.args 0 with
        | Form.Hash h -> h
        | _ -> err ~meta:f.Form.meta ~code:"E0203" "the target of `ref` must be a #hash"
      in
      match the_sym ~what:"the ref kind" f (List.nth f.Form.args 1) with
      | "term" -> node (Ref (h, Term))
      | "con" -> node (Ref (h, Con))
      | "op" -> node (Ref (h, Op))
      | k ->
          err ~meta:f.Form.meta ~code:"E0210" "invalid ref kind `%s`: expected term, con, or op" k)
  | "lam" ->
      expect_arity f 2;
      let params =
        List.map pat_of (the_group ~what:"the parameter list" f (List.nth f.Form.args 0))
      in
      let body = expr_of (the_form ~what:"the body" f (List.nth f.Form.args 1)) in
      List.iter
        (fun p ->
          if not (is_irrefutable p) then
            err ~meta:p.meta ~code:"E0205"
              "`lam` parameters must be irrefutable patterns (pwild, pvar, or ptuple/pas of those)")
        params;
      node (Lam (params, body))
  | "app" ->
      expect_min_arity f 1;
      let fn = expr_of (the_form ~what:"the function" f (List.nth f.Form.args 0)) in
      let args =
        List.map (fun a -> expr_of (the_form ~what:"an argument" f a)) (List.tl f.Form.args)
      in
      node (App (fn, args))
  | "let" ->
      expect_arity f 4;
      let isrec =
        match the_sym ~what:"the rec flag" f (List.nth f.Form.args 0) with
        | "rec" -> true
        | "nonrec" -> false
        | s -> err ~meta:f.Form.meta ~code:"E0211" "invalid rec flag `%s`: expected rec or nonrec" s
      in
      let binder = pat_of (the_form ~what:"the binder" f (List.nth f.Form.args 1)) in
      let value = expr_of (the_form ~what:"the bound value" f (List.nth f.Form.args 2)) in
      let body = expr_of (the_form ~what:"the body" f (List.nth f.Form.args 3)) in
      if isrec then
        (* rec-shape checks come first so `(let rec (plit 0) ...)` reports the specific
           E0207, not the generic irrefutability error *)
        match (binder.it, value.it) with
        | PVar _, Lam _ -> node (Let { isrec; binder; value; body })
        | PVar _, _ -> err ~meta:value.meta ~code:"E0208" "the value of `let rec` must be a `lam`"
        | _ -> err ~meta:binder.meta ~code:"E0207" "the binder of `let rec` must be a `pvar`"
      else begin
        if not (is_irrefutable binder) then
          err ~meta:binder.meta ~code:"E0206" "`let` binders must be irrefutable patterns";
        node (Let { isrec; binder; value; body })
      end
  | "match" ->
      expect_min_arity f 1;
      let scrutinee = expr_of (the_form ~what:"the scrutinee" f (List.nth f.Form.args 0)) in
      let clauses =
        List.map (fun a -> clause_of (the_form ~what:"a clause" f a)) (List.tl f.Form.args)
      in
      if clauses = [] then err ~meta:f.Form.meta ~code:"E0209" "`match` needs at least one clause";
      node (Match (scrutinee, clauses))
  | "tuple" ->
      node (Tuple (List.map (fun a -> expr_of (the_form ~what:"a tuple item" f a)) f.Form.args))
  | "handle" ->
      expect_min_arity f 2;
      let body = expr_of (the_form ~what:"the body" f (List.nth f.Form.args 0)) in
      let ret = ret_of (the_form ~what:"the return clause" f (List.nth f.Form.args 1)) in
      let ops =
        List.map
          (fun a -> opclause_of (the_form ~what:"an op clause" f a))
          (List.filteri (fun i _ -> i >= 2) f.Form.args)
      in
      node (Handle { body; ret; ops })
  | "quote" ->
      expect_arity f 1;
      let payload = the_form ~what:"the quoted form" f (List.nth f.Form.args 0) in
      check_quote_payload payload;
      node (Quote payload)
  | "unquote" -> err ~meta:f.Form.meta ~code:"E0204" "`unquote` is only legal under `quote`"
  | "groupref" -> (
      expect_arity f 1;
      match List.nth f.Form.args 0 with
      | Form.Int i when i >= 0 -> node (GroupRef i)
      | _ ->
          err ~meta:f.Form.meta ~code:"E0203"
            "the index of `groupref` must be a non-negative integer")
  | "ann" ->
      expect_arity f 2;
      let subject = expr_of (the_form ~what:"the subject" f (List.nth f.Form.args 0)) in
      let ty = ty_of (the_form ~what:"the ascription" f (List.nth f.Form.args 1)) in
      node (Ann (subject, ty))
  | h -> err ~meta:f.Form.meta ~code:"E0201" "`%s` is not a kernel expression form" h

(* Inside a quote payload only LIVE (level-0) unquotes splice; a nested quote raises the
   quasiquote level and an unquote lowers it, so an unquote under a nested quote is data
   belonging to the inner quote (conventional quasiquote nesting). Live splices must be valid
   expressions; everything else is uninterpreted data. *)
and check_quote_payload ?(level = 0) (f : Form.t) =
  if f.Form.head = "unquote" && level = 0 then begin
    expect_arity f 1;
    ignore (expr_of (the_form ~what:"the spliced expression" f (List.nth f.Form.args 0)))
  end
  else
    let level =
      match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    List.iter (function Form.F g -> check_quote_payload ~level g | _ -> ()) f.Form.args

and clause_of (f : Form.t) : clause =
  if f.Form.head <> "clause" then
    err ~meta:f.Form.meta ~code:"E0201" "expected a `clause` form, got `%s`" f.Form.head;
  expect_arity f 2;
  let cpat = pat_of (the_form ~what:"the pattern" f (List.nth f.Form.args 0)) in
  let cbody = expr_of (the_form ~what:"the clause body" f (List.nth f.Form.args 1)) in
  { cpat; cbody; cmeta = f.Form.meta }

and ret_of (f : Form.t) : ret =
  if f.Form.head <> "ret" then
    err ~meta:f.Form.meta ~code:"E0212"
      "`handle` needs exactly one `ret` clause as its second argument, got `%s`" f.Form.head;
  expect_arity f 2;
  let rbinder = pat_of (the_form ~what:"the return binder" f (List.nth f.Form.args 0)) in
  let rbody = expr_of (the_form ~what:"the return body" f (List.nth f.Form.args 1)) in
  { rbinder; rbody; rmeta = f.Form.meta }

and opclause_of (f : Form.t) : opclause =
  if f.Form.head = "ret" then
    err ~meta:f.Form.meta ~code:"E0212" "`handle` has more than one `ret` clause";
  if f.Form.head <> "opclause" then
    err ~meta:f.Form.meta ~code:"E0201" "expected an `opclause` form, got `%s`" f.Form.head;
  expect_arity f 4;
  let op = the_gref ~what:"the operation" f (List.nth f.Form.args 0) in
  let params = List.map pat_of (the_group ~what:"the parameter list" f (List.nth f.Form.args 1)) in
  let resume = the_sym ~what:"the resume name" f (List.nth f.Form.args 2) in
  let obody = expr_of (the_form ~what:"the op clause body" f (List.nth f.Form.args 3)) in
  { op; params; resume; obody; ometa = f.Form.meta }

and pat_of (f : Form.t) : pat =
  let node it = { it; meta = f.Form.meta } in
  match f.Form.head with
  | "pwild" ->
      expect_arity f 0;
      node PWild
  | "pvar" ->
      expect_arity f 1;
      node (PVar (the_sym ~what:"the variable name" f (List.nth f.Form.args 0)))
  | "plit" ->
      expect_arity f 1;
      node (PLit (the_lit ~what:"the literal" f (List.nth f.Form.args 0)))
  | "pcon" ->
      expect_min_arity f 1;
      let con = the_gref ~what:"the constructor" f (List.nth f.Form.args 0) in
      let args =
        List.map (fun a -> pat_of (the_form ~what:"a subpattern" f a)) (List.tl f.Form.args)
      in
      node (PCon (con, args))
  | "ptuple" ->
      node (PTuple (List.map (fun a -> pat_of (the_form ~what:"a tuple item" f a)) f.Form.args))
  | "pas" ->
      expect_arity f 2;
      let name = the_sym ~what:"the binder name" f (List.nth f.Form.args 0) in
      let inner = pat_of (the_form ~what:"the inner pattern" f (List.nth f.Form.args 1)) in
      node (PAs (name, inner))
  | h -> err ~meta:f.Form.meta ~code:"E0201" "`%s` is not a kernel pattern form" h

and ty_of (f : Form.t) : ty =
  let node it = { it; meta = f.Form.meta } in
  match f.Form.head with
  | "tref" ->
      expect_arity f 1;
      node (TRef (the_gref ~what:"the type reference" f (List.nth f.Form.args 0)))
  | "tvar" ->
      expect_arity f 1;
      node (TVar (the_sym ~what:"the type variable" f (List.nth f.Form.args 0)))
  | "tapp" ->
      expect_min_arity f 2;
      let head = ty_of (the_form ~what:"the type head" f (List.nth f.Form.args 0)) in
      let args =
        List.map (fun a -> ty_of (the_form ~what:"a type argument" f a)) (List.tl f.Form.args)
      in
      node (TApp (head, args))
  | "tarrow" ->
      expect_arity f 3;
      let params =
        List.map ty_of (the_group ~what:"the parameter types" f (List.nth f.Form.args 0))
      in
      let row = row_of (the_form ~what:"the effect row" f (List.nth f.Form.args 1)) in
      let result = ty_of (the_form ~what:"the result type" f (List.nth f.Form.args 2)) in
      node (TArrow (params, row, result))
  | "ttuple" ->
      node (TTuple (List.map (fun a -> ty_of (the_form ~what:"a tuple item" f a)) f.Form.args))
  | "tforall" ->
      expect_arity f 3;
      let tyvars =
        List.map
          (fun g ->
            if g.Form.head <> "tvar" then
              err ~meta:g.Form.meta ~code:"E0203" "type variables in `tforall` must be `tvar` forms";
            expect_arity g 1;
            the_sym ~what:"the type variable" g (List.nth g.Form.args 0))
          (the_group ~what:"the type variables" f (List.nth f.Form.args 0))
      in
      let rowvars =
        List.map
          (fun g ->
            if g.Form.head <> "rvar" then
              err ~meta:g.Form.meta ~code:"E0203" "row variables in `tforall` must be `rvar` forms";
            expect_arity g 1;
            the_sym ~what:"the row variable" g (List.nth g.Form.args 0))
          (the_group ~what:"the row variables" f (List.nth f.Form.args 1))
      in
      let body = ty_of (the_form ~what:"the body" f (List.nth f.Form.args 2)) in
      node (TForall (tyvars, rowvars, body))
  | h -> err ~meta:f.Form.meta ~code:"E0201" "`%s` is not a kernel type form" h

and row_of (f : Form.t) : row =
  if f.Form.head <> "row" then
    err ~meta:f.Form.meta ~code:"E0201" "expected a `row` form, got `%s`" f.Form.head;
  let effects, rvar =
    let rec go acc = function
      | [] -> (List.rev acc, None)
      | [ Form.Sym v ] -> (List.rev acc, Some v)
      | Form.F g :: rest ->
          if g.Form.head <> "eref" then
            err ~meta:g.Form.meta ~code:"E0203" "row effects must be `eref` forms";
          expect_arity g 1;
          go (the_gref ~what:"the effect" g (List.nth g.Form.args 0) :: acc) rest
      | _ ->
          err ~meta:f.Form.meta ~code:"E0203"
            "`row` takes `eref` forms and an optional trailing row variable"
    in
    go [] f.Form.args
  in
  { effects; rvar; wmeta = f.Form.meta }

let binding_of (f : Form.t) : binding =
  if f.Form.head <> "binding" then
    err ~meta:f.Form.meta ~code:"E0201" "expected a `binding` form, got `%s`" f.Form.head;
  expect_arity f 3;
  let bname = the_sym ~what:"the binding name" f (List.nth f.Form.args 0) in
  let annot =
    match the_group ~what:"the annotation" f (List.nth f.Form.args 1) with
    | [] -> None
    | [ t ] -> Some (ty_of t)
    | _ -> err ~meta:f.Form.meta ~code:"E0202" "a binding annotation group holds at most one type"
  in
  let value = expr_of (the_form ~what:"the bound value" f (List.nth f.Form.args 2)) in
  { bname; annot; value; bmeta = f.Form.meta }

let conspec_of (f : Form.t) : conspec =
  if f.Form.head <> "con" then
    err ~meta:f.Form.meta ~code:"E0201" "expected a `con` constructor spec, got `%s`" f.Form.head;
  expect_min_arity f 1;
  let con_name = the_sym ~what:"the constructor name" f (List.nth f.Form.args 0) in
  let fields =
    List.map
      (fun a ->
        let g = the_form ~what:"a field" f a in
        if g.Form.head <> "field" then
          err ~meta:g.Form.meta ~code:"E0201" "expected a `field` form, got `%s`" g.Form.head;
        match g.Form.args with
        | [ Form.F t ] -> { label = None; fty = ty_of t; fmeta = g.Form.meta }
        | [ Form.Sym l; Form.F t ] -> { label = Some l; fty = ty_of t; fmeta = g.Form.meta }
        | _ ->
            err ~meta:g.Form.meta ~code:"E0203" "`field` takes an optional label symbol and a type")
      (List.tl f.Form.args)
  in
  { con_name; fields; kmeta = f.Form.meta }

let opspec_of (f : Form.t) : opspec =
  if f.Form.head <> "op" then
    err ~meta:f.Form.meta ~code:"E0201" "expected an `op` operation spec, got `%s`" f.Form.head;
  expect_arity f 3;
  let op_name = the_sym ~what:"the operation name" f (List.nth f.Form.args 0) in
  let op_params =
    List.map ty_of (the_group ~what:"the parameter types" f (List.nth f.Form.args 1))
  in
  let op_result = ty_of (the_form ~what:"the result type" f (List.nth f.Form.args 2)) in
  { op_name; op_params; op_result; smeta = f.Form.meta }

let tvars_group ~what (f : Form.t) arg =
  List.map
    (fun g ->
      if g.Form.head <> "tvar" then
        err ~meta:g.Form.meta ~code:"E0203" "%s must be `tvar` forms" what;
      expect_arity g 1;
      the_sym ~what:"the type variable" g (List.nth g.Form.args 0))
    (the_group ~what f arg)

let decl_of (f : Form.t) : decl =
  let node it = { it; meta = f.Form.meta } in
  match f.Form.head with
  | "defterm" ->
      expect_arity f 1;
      let bindings =
        List.map binding_of (the_group ~what:"the binding group" f (List.nth f.Form.args 0))
      in
      if bindings = [] then
        err ~meta:f.Form.meta ~code:"E0202" "`defterm` needs at least one binding";
      node (DefTerm bindings)
  | "deftype" ->
      expect_min_arity f 3;
      let tname = the_sym ~what:"the type name" f (List.nth f.Form.args 0) in
      let tvars = tvars_group ~what:"the type parameters" f (List.nth f.Form.args 1) in
      let cons =
        List.map
          (fun a -> conspec_of (the_form ~what:"a constructor spec" f a))
          (List.filteri (fun i _ -> i >= 2) f.Form.args)
      in
      node (DefType { tname; tvars; cons })
  | "defeffect" ->
      expect_min_arity f 3;
      let ename = the_sym ~what:"the effect name" f (List.nth f.Form.args 0) in
      let evars = tvars_group ~what:"the effect parameters" f (List.nth f.Form.args 1) in
      let ops =
        List.map
          (fun a -> opspec_of (the_form ~what:"an operation spec" f a))
          (List.filteri (fun i _ -> i >= 2) f.Form.args)
      in
      node (DefEffect { ename; evars; ops })
  | h -> err ~meta:f.Form.meta ~code:"E0201" "`%s` is not a kernel declaration form" h

let decl_heads = [ "defterm"; "deftype"; "defeffect" ]

(* Public entry points: exceptions stay inside. *)

(** [expr_of_form f] validates [f] as a kernel expression. *)
let expr_of_form (f : Form.t) : (expr, Diag.t list) result =
  match expr_of f with e -> Ok e | exception Err d -> Error [ d ]

(** [decl_of_form f] validates [f] as a kernel declaration. *)
let decl_of_form (f : Form.t) : (decl, Diag.t list) result =
  match decl_of f with d -> Ok d | exception Err d -> Error [ d ]

(** [pat_of_form f] validates [f] as a kernel pattern. *)
let pat_of_form (f : Form.t) : (pat, Diag.t list) result =
  match pat_of f with p -> Ok p | exception Err d -> Error [ d ]

(** [ty_of_form f] validates [f] as a kernel type. *)
let ty_of_form (f : Form.t) : (ty, Diag.t list) result =
  match ty_of f with ty -> Ok ty | exception Err d -> Error [ d ]

(** [row_of_form f] validates [f] as a kernel effect row. *)
let row_of_form (f : Form.t) : (row, Diag.t list) result =
  match row_of f with row -> Ok row | exception Err d -> Error [ d ]

(** [of_form f] validates [f] as a declaration when its head is one, otherwise as an expression. *)
let of_form (f : Form.t) : (top, Diag.t list) result =
  if List.mem f.Form.head decl_heads then Result.map (fun d -> Decl d) (decl_of_form f)
  else Result.map (fun e -> Expr e) (expr_of_form f)

(* ------------------------------------------------------------------ *)
(* to_form: the injective inverse, meta-preserving where held.         *)
(* ------------------------------------------------------------------ *)

let form ?(meta = Meta.empty) head args = Form.form ~meta head args
let group forms = Form.F (form "group" (List.map (fun f -> Form.F f) forms))
let lit_arg = function LInt i -> Form.Int i | LReal r -> Form.Real r | LText s -> Form.Text s
let gref_arg = function Named s -> Form.Sym s | Hashed h -> Form.Hash h
let refkind_sym = function Term -> "term" | Con -> "con" | Op -> "op"

let rec expr_to_form (e : expr) : Form.t =
  let meta = e.meta in
  match e.it with
  | Lit l -> form ~meta "lit" [ lit_arg l ]
  | Var x -> form ~meta "var" [ Form.Sym x ]
  | Ref (h, k) -> form ~meta "ref" [ Form.Hash h; Form.Sym (refkind_sym k) ]
  | Lam (params, body) ->
      form ~meta "lam" [ group (List.map pat_to_form params); Form.F (expr_to_form body) ]
  | App (fn, args) ->
      form ~meta "app" (Form.F (expr_to_form fn) :: List.map (fun a -> Form.F (expr_to_form a)) args)
  | Let { isrec; binder; value; body } ->
      form ~meta "let"
        [
          Form.Sym (if isrec then "rec" else "nonrec");
          Form.F (pat_to_form binder);
          Form.F (expr_to_form value);
          Form.F (expr_to_form body);
        ]
  | Match (scrutinee, clauses) ->
      form ~meta "match"
        (Form.F (expr_to_form scrutinee)
        :: List.map
             (fun { cpat; cbody; cmeta } ->
               Form.F
                 (form ~meta:cmeta "clause"
                    [ Form.F (pat_to_form cpat); Form.F (expr_to_form cbody) ]))
             clauses)
  | Tuple items -> form ~meta "tuple" (List.map (fun i -> Form.F (expr_to_form i)) items)
  | Handle { body; ret = { rbinder; rbody; rmeta }; ops } ->
      form ~meta "handle"
        (Form.F (expr_to_form body)
        :: Form.F
             (form ~meta:rmeta "ret" [ Form.F (pat_to_form rbinder); Form.F (expr_to_form rbody) ])
        :: List.map
             (fun { op; params; resume; obody; ometa } ->
               Form.F
                 (form ~meta:ometa "opclause"
                    [
                      gref_arg op;
                      group (List.map pat_to_form params);
                      Form.Sym resume;
                      Form.F (expr_to_form obody);
                    ]))
             ops)
  | Quote payload -> form ~meta "quote" [ Form.F payload ]
  | Unquote splice -> form ~meta "unquote" [ Form.F (expr_to_form splice) ]
  | Ann (subject, ty) -> form ~meta "ann" [ Form.F (expr_to_form subject); Form.F (ty_to_form ty) ]
  | GroupRef i -> form ~meta "groupref" [ Form.Int i ]

and pat_to_form (p : pat) : Form.t =
  let meta = p.meta in
  match p.it with
  | PWild -> form ~meta "pwild" []
  | PVar x -> form ~meta "pvar" [ Form.Sym x ]
  | PLit l -> form ~meta "plit" [ lit_arg l ]
  | PCon (con, args) ->
      form ~meta "pcon" (gref_arg con :: List.map (fun a -> Form.F (pat_to_form a)) args)
  | PTuple items -> form ~meta "ptuple" (List.map (fun i -> Form.F (pat_to_form i)) items)
  | PAs (name, inner) -> form ~meta "pas" [ Form.Sym name; Form.F (pat_to_form inner) ]

and ty_to_form (t : ty) : Form.t =
  let meta = t.meta in
  match t.it with
  | TRef r -> form ~meta "tref" [ gref_arg r ]
  | TVar a -> form ~meta "tvar" [ Form.Sym a ]
  | TApp (head, args) ->
      form ~meta "tapp" (Form.F (ty_to_form head) :: List.map (fun a -> Form.F (ty_to_form a)) args)
  | TArrow (params, row, result) ->
      form ~meta "tarrow"
        [ group (List.map ty_to_form params); Form.F (row_to_form row); Form.F (ty_to_form result) ]
  | TTuple items -> form ~meta "ttuple" (List.map (fun i -> Form.F (ty_to_form i)) items)
  | TForall (tyvars, rowvars, body) ->
      form ~meta "tforall"
        [
          group (List.map (fun v -> form "tvar" [ Form.Sym v ]) tyvars);
          group (List.map (fun v -> form "rvar" [ Form.Sym v ]) rowvars);
          Form.F (ty_to_form body);
        ]

and row_to_form ({ effects; rvar; wmeta } : row) : Form.t =
  form ~meta:wmeta "row"
    (List.map (fun e -> Form.F (form "eref" [ gref_arg e ])) effects
    @ match rvar with Some v -> [ Form.Sym v ] | None -> [])

let binding_to_form { bname; annot; value; bmeta } =
  form ~meta:bmeta "binding"
    [
      Form.Sym bname;
      group (match annot with Some t -> [ ty_to_form t ] | None -> []);
      Form.F (expr_to_form value);
    ]

let decl_to_form (d : decl) : Form.t =
  let meta = d.meta in
  match d.it with
  | DefTerm bindings -> form ~meta "defterm" [ group (List.map binding_to_form bindings) ]
  | DefType { tname; tvars; cons } ->
      form ~meta "deftype"
        (Form.Sym tname
        :: group (List.map (fun v -> form "tvar" [ Form.Sym v ]) tvars)
        :: List.map
             (fun { con_name; fields; kmeta } ->
               Form.F
                 (form ~meta:kmeta "con"
                    (Form.Sym con_name
                    :: List.map
                         (fun { label; fty; fmeta } ->
                           Form.F
                             (form ~meta:fmeta "field"
                                (match label with
                                | Some l -> [ Form.Sym l; Form.F (ty_to_form fty) ]
                                | None -> [ Form.F (ty_to_form fty) ])))
                         fields)))
             cons)
  | DefEffect { ename; evars; ops } ->
      form ~meta "defeffect"
        (Form.Sym ename
        :: group (List.map (fun v -> form "tvar" [ Form.Sym v ]) evars)
        :: List.map
             (fun { op_name; op_params; op_result; smeta } ->
               Form.F
                 (form ~meta:smeta "op"
                    [
                      Form.Sym op_name;
                      group (List.map ty_to_form op_params);
                      Form.F (ty_to_form op_result);
                    ]))
             ops)

(** [to_form t] converts back to the triple encoding, preserving node meta. *)
let to_form = function Decl d -> decl_to_form d | Expr e -> expr_to_form e
