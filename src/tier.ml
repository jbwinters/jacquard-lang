(** Effect-row tiers and handler disciplines (PF.2 phase 1, docs/native-compilation.md).

    The native route compiles each arrow by its row. This module gives that classification a name, a
    stable rendering for store sidecars, and the raw material for the call-site statistics the
    design doc's dominant-case assumption rests on. An arrow's tier is [repr_row]'s answer at
    generalization time; a handler clause's discipline is a syntactic reading of how it uses its
    resumption. Neither adds inference. *)

open Types

(** An arrow's tier, read off its effect row. [Data] marks non-arrows (no call semantics). [RowPoly]
    arrows have an unconstrained row, decided per call site after specialization. [Effectful] rows
    name their capabilities; [opened] means the tail stayed open (at-most semantics), closed means
    exactly these. *)
type arrow_tier = Data | Pure | RowPoly | Effectful of { effects : Hash.t list; opened : bool }

(** How an op clause uses its resumption, syntactically:

    - [Aborting]: no path resumes. The continuation is dropped, exception-style.
    - [TailResumptive]: every path resumes exactly once, in tail position — the evidence-passing
      fast path (no continuation is ever materialized).
    - [OneShot]: at most one resume per path, but some path resumes off tail or not at all —
      selective capture territory.
    - [MultiShot]: the resumption escapes as a value or a path resumes more than once — continuation
      cloning, priced by branch count. *)
type discipline = Aborting | TailResumptive | OneShot | MultiShot

(** What sits in an application's function position, for bucketing call-site statistics:
    constructors and op performs have rows fixed by construction (empty and singleton respectively),
    so they are reported apart from genuine function calls. *)
type app_kind = KCon | KOp | KFn

(* ------------------------------------------------------------------ *)
(* Arrow classification                                                *)
(* ------------------------------------------------------------------ *)

let classify_row (r : row) : arrow_tier =
  let r = repr_row r in
  match (r.effects, r.tail) with
  | [], RClosed -> Pure
  | [], _ -> RowPoly
  | effects, RClosed -> Effectful { effects; opened = false }
  | effects, _ -> Effectful { effects; opened = true }

(** [classify_ty t] is the tier of [t]'s outermost arrow row, [Data] for non-arrows. *)
let classify_ty (t : ty) : arrow_tier =
  match repr t with
  | TArrow (_, row, _) | TVariadicArrow (_, row, _) -> classify_row row
  | _ -> Data

(* ------------------------------------------------------------------ *)
(* Sidecar rendering (stable: names can be rebound, hashes cannot)     *)
(* ------------------------------------------------------------------ *)

let to_string (t : arrow_tier) : string =
  match t with
  | Data -> "data"
  | Pure -> "pure"
  | RowPoly -> "row-poly"
  | Effectful { effects; opened } ->
      Printf.sprintf "effectful%s:%s"
        (if opened then "-open" else "")
        (String.concat "," (List.map Hash.to_hex effects))

let of_string (s : string) : arrow_tier option =
  let effects_of hex =
    let parts = if hex = "" then [] else String.split_on_char ',' hex in
    List.fold_left
      (fun acc p -> match (acc, Hash.of_hex p) with Some hs, Some h -> Some (h :: hs) | _ -> None)
      (Some []) parts
    |> Option.map List.rev
  in
  match s with
  | "data" -> Some Data
  | "pure" -> Some Pure
  | "row-poly" -> Some RowPoly
  | _ -> (
      match String.index_opt s ':' with
      | Some i -> (
          let head = String.sub s 0 i in
          let hex = String.sub s (i + 1) (String.length s - i - 1) in
          match (head, effects_of hex) with
          | "effectful", Some effects -> Some (Effectful { effects; opened = false })
          | "effectful-open", Some effects -> Some (Effectful { effects; opened = true })
          | _ -> None)
      | None -> None)

let discipline_to_string = function
  | Aborting -> "aborting"
  | TailResumptive -> "tail-resumptive"
  | OneShot -> "one-shot"
  | MultiShot -> "multi-shot"

(* ------------------------------------------------------------------ *)
(* Resume-usage analysis                                               *)
(* ------------------------------------------------------------------ *)

(* Per-path resume usage. [max_calls]/[min_calls] bound the applications of the resumption on any
   single exclusive path; [nontail] counts applications off tail position (worst path); [escapes]
   counts uses as a value — passed, tupled, or captured under a lam, where the call multiplicity
   is no longer syntactically visible. *)
type usage = { max_calls : int; min_calls : int; nontail : int; escapes : int }

let zero = { max_calls = 0; min_calls = 0; nontail = 0; escapes = 0 }

(* both parts run *)
let seq a b =
  {
    max_calls = a.max_calls + b.max_calls;
    min_calls = a.min_calls + b.min_calls;
    nontail = a.nontail + b.nontail;
    escapes = a.escapes + b.escapes;
  }

(* exactly one part runs *)
let alt a b =
  {
    max_calls = max a.max_calls b.max_calls;
    min_calls = min a.min_calls b.min_calls;
    nontail = max a.nontail b.nontail;
    escapes = max a.escapes b.escapes;
  }

let rec pat_binds name (p : Kernel.pat) : bool =
  match p.Kernel.it with
  | Kernel.PVar x -> x = name
  | Kernel.PAs (x, p) -> x = name || pat_binds name p
  | Kernel.PCon (_, ps) | Kernel.PTuple ps -> List.exists (pat_binds name) ps
  | Kernel.PWild | Kernel.PLit _ -> false

(* [usage ~name ~tail e]: how [e] uses the resumption bound as [name]. [tail] means [e]'s value is
   the clause's value. The walk is conservative: anything under a lam or inside another handler
   counts against tail-resumptiveness rather than for it. *)
let rec usage ~name ~tail (e : Kernel.expr) : usage =
  match e.Kernel.it with
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ -> zero
  | Kernel.Var x -> if x = name then { zero with escapes = 1 } else zero
  | Kernel.Lam (params, body) ->
      if List.exists (pat_binds name) params then zero
      else
        (* the lam may run any number of times; every use inside is an escape *)
        let u = usage ~name ~tail:false body in
        { zero with escapes = u.max_calls + u.nontail + u.escapes }
  | Kernel.App (fn, args) -> (
      let args_u = List.fold_left (fun acc a -> seq acc (usage ~name ~tail:false a)) zero args in
      match fn.Kernel.it with
      | Kernel.Var x when x = name ->
          seq args_u
            { max_calls = 1; min_calls = 1; nontail = (if tail then 0 else 1); escapes = 0 }
      | _ -> seq (usage ~name ~tail:false fn) args_u)
  | Kernel.Let { isrec; binder; value; body } ->
      let shadowed = pat_binds name binder in
      let value_u =
        if isrec && shadowed then zero (* let rec scopes the binder over its own value *)
        else usage ~name ~tail:false value
      in
      if shadowed then value_u else seq value_u (usage ~name ~tail body)
  | Kernel.Match (scrutinee, clauses) ->
      let arms =
        List.map
          (fun { Kernel.cpat; cbody; _ } ->
            if pat_binds name cpat then zero else usage ~name ~tail cbody)
          clauses
      in
      let arms_u = match arms with [] -> zero | first :: rest -> List.fold_left alt first rest in
      seq (usage ~name ~tail:false scrutinee) arms_u
  | Kernel.Tuple items ->
      List.fold_left (fun acc i -> seq acc (usage ~name ~tail:false i)) zero items
  | Kernel.Handle { body; ret = { rbinder; rbody; _ }; ops } ->
      (* an enclosing handler transforms the result, so nothing inside is clause-tail *)
      let body_u = usage ~name ~tail:false body in
      let ret_u = if pat_binds name rbinder then zero else usage ~name ~tail:false rbody in
      let ops_u =
        List.fold_left
          (fun acc (oc : Kernel.opclause) ->
            if oc.Kernel.resume = name || List.exists (pat_binds name) oc.Kernel.params then acc
            else seq acc (usage ~name ~tail:false oc.Kernel.obody))
          zero ops
      in
      seq body_u (seq ret_u ops_u)
  | Kernel.Quote payload ->
      (* quoted code is data, but live splices evaluate at quote time (same walk as the checker) *)
      let rec splices ?(level = 0) acc (f : Form.t) =
        if f.Form.head = "unquote" && level = 0 then
          match f.Form.args with
          | [ Form.F sp ] -> (
              match Kernel.expr_of_form sp with
              | Ok se -> seq acc (usage ~name ~tail:false se)
              | Error _ -> acc)
          | _ -> acc
        else
          let level =
            match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
          in
          List.fold_left
            (fun acc -> function Form.F g -> splices ~level acc g | _ -> acc)
            acc f.Form.args
      in
      splices zero payload
  | Kernel.Unquote inner -> usage ~name ~tail:false inner
  | Kernel.Ann (subject, _) -> usage ~name ~tail subject

(** [discipline ~resume obody] classifies one op clause by its resume usage. *)
let discipline ~resume (obody : Kernel.expr) : discipline =
  let u = usage ~name:resume ~tail:true obody in
  if u.escapes > 0 || u.max_calls > 1 then MultiShot
  else if u.max_calls = 0 then Aborting
  else if u.nontail = 0 && u.min_calls = 1 then TailResumptive
  else OneShot
