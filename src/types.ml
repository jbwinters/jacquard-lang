(** Internal types, effect rows, and the unifier (plan W3.1).

    Types use mutable unification variables with levels for let-generalization (the standard Rémy
    scheme: a variable's level is the [let] depth where it was created; generalization at level L
    quantifies exactly the variables deeper than L). Skolems are rigid variables introduced when
    checking against an annotation's [tforall]; they unify only with themselves.

    Effect rows are set-semantics (Leijen, POPL 2017, simplified: no duplicate labels): a sorted,
    deduplicated set of effect hashes plus an optional tail. Row unification cancels the
    intersection; a closed row absorbs a remainder only if that remainder is empty; two open rows
    bind each tail to the other side's remainder plus a fresh common tail. Occurs checks run on both
    type and row variables.

    Failure modes surface as [Unify_error] carrying a rendered mismatch; the checker (W3.2+)
    converts these to diagnostics with spans. *)

type level = int

type ty =
  | TCon of Hash.t * ty list  (** a declared (nominal) type applied to arguments *)
  | TTuple of ty list
  | TArrow of ty list * row * ty  (** the row lives on the arrow (design thesis) *)
  | TVar of tvar ref
  | TSkolem of int * string  (** rigid annotation variable; the string is its source name *)

and tvar = Unbound of { id : int; level : level } | Link of ty

and row = { effects : Hash.t list; tail : rtail }
(** [effects] is sorted and deduplicated after {!repr_row}. *)

and rtail = RClosed | RVar of rvar ref | RSkolem of int * string
and rvar = RUnbound of { id : int; level : level } | RLink of row

exception Unify_error of string

(* ------------------------------------------------------------------ *)
(* Construction                                                        *)
(* ------------------------------------------------------------------ *)

let counter = Atomic.make 0
let fresh_id () = Atomic.fetch_and_add counter 1 + 1
let new_tvar level = TVar (ref (Unbound { id = fresh_id (); level }))
let new_rvar level : rtail = RVar (ref (RUnbound { id = fresh_id (); level }))
let closed_row effects = { effects = List.sort_uniq Hash.compare effects; tail = RClosed }

let open_row level effects =
  { effects = List.sort_uniq Hash.compare effects; tail = new_rvar level }

let empty_row = { effects = []; tail = RClosed }

(* ------------------------------------------------------------------ *)
(* Normalization                                                       *)
(* ------------------------------------------------------------------ *)

(** Follow type-variable links to the representative. *)
let rec repr (t : ty) : ty =
  match t with
  | TVar ({ contents = Link t' } as r) ->
      let t'' = repr t' in
      r := Link t'';
      t''
  | t -> t

(** Normalize a row: follow tail links and merge their effect sets. *)
let rec repr_row (r : row) : row =
  match r.tail with
  | RVar { contents = RLink inner } ->
      let inner = repr_row inner in
      { effects = List.sort_uniq Hash.compare (r.effects @ inner.effects); tail = inner.tail }
  | _ -> { r with effects = List.sort_uniq Hash.compare r.effects }

(* ------------------------------------------------------------------ *)
(* Occurs check and level adjustment                                   *)
(* ------------------------------------------------------------------ *)

let rec occurs_adjust (id : int) (lvl : level) (t : ty) : unit =
  match repr t with
  | TVar ({ contents = Unbound { id = id'; level = l' } } as r) ->
      if id = id' then raise (Unify_error "occurs check: a type would contain itself");
      if l' > lvl then r := Unbound { id = id'; level = lvl }
  | TVar { contents = Link _ } -> assert false
  | TSkolem _ -> ()
  | TCon (_, args) -> List.iter (occurs_adjust id lvl) args
  | TTuple items -> List.iter (occurs_adjust id lvl) items
  | TArrow (params, row, result) ->
      List.iter (occurs_adjust id lvl) params;
      row_occurs_adjust_ty id lvl row;
      occurs_adjust id lvl result

and row_occurs_adjust_ty id lvl row =
  (* type-var occurs never fails through a row, but nested arrows hide in effect args?
     effects are bare hashes, so nothing to do beyond the tail level (row vars are a
     separate namespace) *)
  ignore (id, lvl, row)

let rec row_occurs_adjust (id : int) (lvl : level) (t : ty) : unit =
  match repr t with
  | TVar _ | TSkolem _ -> ()
  | TCon (_, args) -> List.iter (row_occurs_adjust id lvl) args
  | TTuple items -> List.iter (row_occurs_adjust id lvl) items
  | TArrow (params, row, result) ->
      List.iter (row_occurs_adjust id lvl) params;
      row_occurs_in_row id lvl row;
      row_occurs_adjust id lvl result

and row_occurs_in_row id lvl row =
  let row = repr_row row in
  match row.tail with
  | RVar ({ contents = RUnbound { id = id'; level = l' } } as r) ->
      if id = id' then raise (Unify_error "occurs check: a row would contain itself");
      if l' > lvl then r := RUnbound { id = id'; level = lvl }
  | _ -> ()

(* ------------------------------------------------------------------ *)
(* Unification                                                         *)
(* ------------------------------------------------------------------ *)

let hash_set_diff a b = List.filter (fun h -> not (List.exists (Hash.equal h) b)) a

let rec unify (a : ty) (b : ty) : unit =
  let a = repr a and b = repr b in
  if a == b then ()
  else
    match (a, b) with
    | TVar ({ contents = Unbound { id; level } } as r), t
    | t, TVar ({ contents = Unbound { id; level } } as r) -> (
        match repr t with
        | TVar { contents = Unbound { id = id'; _ } } when id = id' -> ()
        | t ->
            occurs_adjust id level t;
            row_var_levels level t;
            r := Link t)
    | TSkolem (i, _), TSkolem (j, _) when i = j -> ()
    | TCon (h1, args1), TCon (h2, args2) when Hash.equal h1 h2 ->
        if List.length args1 <> List.length args2 then
          raise (Unify_error "type constructor arity mismatch");
        List.iter2 unify args1 args2
    | TTuple xs, TTuple ys when List.length xs = List.length ys -> List.iter2 unify xs ys
    | TArrow (p1, r1, t1), TArrow (p2, r2, t2) when List.length p1 = List.length p2 ->
        List.iter2 unify p1 p2;
        unify_rows r1 r2;
        unify t1 t2
    | _ -> raise (Unify_error "type mismatch")

(* when binding a type var at [level], row vars inside the bound type must not outlive it *)
and row_var_levels level t =
  match repr t with
  | TVar _ | TSkolem _ | TCon (_, []) -> ()
  | TCon (_, args) -> List.iter (row_var_levels level) args
  | TTuple items -> List.iter (row_var_levels level) items
  | TArrow (params, row, result) ->
      List.iter (row_var_levels level) params;
      (let row = repr_row row in
       match row.tail with
       | RVar ({ contents = RUnbound { id; level = l' } } as r) when l' > level ->
           r := RUnbound { id; level }
       | _ -> ());
      row_var_levels level result

(** Row unification (module doc): cancel the intersection, then case on the tails. *)
and unify_rows (ra : row) (rb : row) : unit =
  let ra = repr_row ra and rb = repr_row rb in
  let only_a = hash_set_diff ra.effects rb.effects in
  let only_b = hash_set_diff rb.effects ra.effects in
  match (ra.tail, rb.tail) with
  | RClosed, RClosed ->
      if only_a <> [] || only_b <> [] then raise (Unify_error "closed effect rows differ")
  | RSkolem (i, _), RSkolem (j, _) when i = j ->
      if only_a <> [] || only_b <> [] then
        raise (Unify_error "effect rows with the same rigid tail differ")
  | RClosed, RVar rv | RSkolem _, RVar rv ->
      (* the flexible side may not have extra effects the fixed side lacks *)
      if only_b <> [] then
        raise
          (Unify_error
             "a closed effect row cannot absorb extra effects; a stored definition passed as a \
              thunk can be eta-expanded at the use site: (lam () (app (var f)))")
      else bind_rvar rv { effects = only_a; tail = ra.tail }
  | RVar rv, RClosed | RVar rv, RSkolem _ ->
      if only_a <> [] then
        raise
          (Unify_error
             "a closed effect row cannot absorb extra effects; a stored definition passed as a \
              thunk can be eta-expanded at the use site: (lam () (app (var f)))")
      else bind_rvar rv { effects = only_b; tail = rb.tail }
  | RVar rva, RVar rvb -> (
      match (!rva, !rvb) with
      | RUnbound { id = ia; _ }, RUnbound { id = ib; _ } when ia = ib ->
          (* same tail: remainders must agree exactly *)
          if only_a <> [] || only_b <> [] then
            raise (Unify_error "occurs check: effect rows with the same tail differ")
      | RUnbound { level = la; _ }, RUnbound { level = lb; _ } ->
          let tail = new_rvar (min la lb) in
          bind_rvar rva { effects = only_b; tail };
          bind_rvar rvb { effects = only_a; tail }
      | _ -> assert false (* repr_row eliminated links *))
  | RClosed, RSkolem _ | RSkolem _, RClosed | RSkolem _, RSkolem _ ->
      raise (Unify_error "effect row tails are incompatible")

and bind_rvar (rv : rvar ref) (r : row) : unit =
  match !rv with
  | RLink _ -> assert false
  | RUnbound { id; level } -> (
      (* occurs: the bound row's tail must not be this very variable *)
      match (repr_row r).tail with
      | RVar { contents = RUnbound { id = id'; _ } } when id = id' ->
          if r.effects = [] then () (* trivial self-link is a no-op *)
          else raise (Unify_error "occurs check: a row would contain itself")
      | _ ->
          (* propagate level ceiling to the new tail *)
          (match (repr_row r).tail with
          | RVar ({ contents = RUnbound { id = id'; level = l' } } as r') when l' > level ->
              r' := RUnbound { id = id'; level }
          | _ -> ());
          rv := RLink r)

(* ------------------------------------------------------------------ *)
(* Schemes: generalize / instantiate                                   *)
(* ------------------------------------------------------------------ *)

type scheme = { ty : ty; gen_level : level }
(** A scheme is a type plus the level at which it was generalized: every unbound variable in [ty]
    with a level strictly greater than [gen_level] is quantified. Monomorphic bindings use
    [gen_level = max_int] (nothing quantified). *)

let mono ty = { ty; gen_level = max_int }

(** [instantiate ~level s] copies [s.ty], replacing each quantified variable (type and row) with a
    fresh variable at [level]. *)
let instantiate ~level (s : scheme) : ty =
  let tmap : (int, ty) Hashtbl.t = Hashtbl.create 8 in
  let rmap : (int, rtail) Hashtbl.t = Hashtbl.create 8 in
  let rec go t =
    match repr t with
    | TVar { contents = Unbound { id; level = l } } when l > s.gen_level -> (
        match Hashtbl.find_opt tmap id with
        | Some v -> v
        | None ->
            let v = new_tvar level in
            Hashtbl.add tmap id v;
            v)
    | (TVar _ | TSkolem _) as t -> t
    | TCon (h, args) -> TCon (h, List.map go args)
    | TTuple items -> TTuple (List.map go items)
    | TArrow (params, row, result) -> TArrow (List.map go params, go_row row, go result)
  and go_row r =
    let r = repr_row r in
    match r.tail with
    | RVar { contents = RUnbound { id; level = l } } when l > s.gen_level -> (
        match Hashtbl.find_opt rmap id with
        | Some tail -> { r with tail }
        | None ->
            let tail = new_rvar level in
            Hashtbl.add rmap id tail;
            { r with tail })
    | _ -> r
  in
  go s.ty

(** [clone_schemes schemes] deep-copies schemes and their mutable unification state while preserving
    sharing between them. Reading the source schemes does not path-compress or otherwise mutate
    them. *)
let clone_schemes (schemes : scheme list) : scheme list =
  let tmap : (int, ty) Hashtbl.t = Hashtbl.create 32 in
  let rmap : (int, rtail) Hashtbl.t = Hashtbl.create 32 in
  let rec go = function
    | TCon (hash, args) -> TCon (hash, List.map go args)
    | TTuple items -> TTuple (List.map go items)
    | TArrow (params, row, result) -> TArrow (List.map go params, go_row row, go result)
    | TSkolem (id, name) -> TSkolem (id, name)
    | TVar reference -> (
        match !reference with
        | Link target -> go target
        | Unbound { id; level } -> (
            match Hashtbl.find_opt tmap id with
            | Some copy -> copy
            | None ->
                let copy = new_tvar level in
                Hashtbl.add tmap id copy;
                copy))
  and go_row row =
    let rec flatten effects = function
      | RClosed -> { effects = List.sort_uniq Hash.compare effects; tail = RClosed }
      | RSkolem (id, name) ->
          { effects = List.sort_uniq Hash.compare effects; tail = RSkolem (id, name) }
      | RVar reference -> (
          match !reference with
          | RLink inner -> flatten (effects @ inner.effects) inner.tail
          | RUnbound { id; level } ->
              let tail =
                match Hashtbl.find_opt rmap id with
                | Some copy -> copy
                | None ->
                    let copy = new_rvar level in
                    Hashtbl.add rmap id copy;
                    copy
              in
              { effects = List.sort_uniq Hash.compare effects; tail })
    in
    flatten row.effects row.tail
  in
  List.map (fun scheme -> { scheme with ty = go scheme.ty }) schemes

(** [unifiable left right] tests compatibility on private copies, leaving both inputs unchanged. *)
let unifiable left right =
  match clone_schemes [ mono left; mono right ] with
  | [ left; right ] -> (
      try
        unify left.ty right.ty;
        true
      with Unify_error _ -> false)
  | _ -> assert false

(** Quantified variable ids of a scheme, for display ([forall a e. ...]). *)
let quantified (s : scheme) : int list * int list =
  let tids = ref [] and rids = ref [] in
  let seen_t = Hashtbl.create 8 and seen_r = Hashtbl.create 8 in
  let rec go t =
    match repr t with
    | TVar { contents = Unbound { id; level } } when level > s.gen_level ->
        if not (Hashtbl.mem seen_t id) then begin
          Hashtbl.add seen_t id ();
          tids := id :: !tids
        end
    | TVar _ | TSkolem _ -> ()
    | TCon (_, args) -> List.iter go args
    | TTuple items -> List.iter go items
    | TArrow (params, row, result) ->
        List.iter go params;
        (let row = repr_row row in
         match row.tail with
         | RVar { contents = RUnbound { id; level } } when level > s.gen_level ->
             if not (Hashtbl.mem seen_r id) then begin
               Hashtbl.add seen_r id ();
               rids := id :: !rids
             end
         | _ -> ());
        go result
  in
  go s.ty;
  (List.rev !tids, List.rev !rids)

(* ------------------------------------------------------------------ *)
(* Display                                                             *)
(* ------------------------------------------------------------------ *)

(** Render a type for signatures and diagnostics. [name_of] maps a type hash to its display name;
    [effect_name_of] can provide a distinct effect namespace projection and defaults to [name_of].
    Quantified/unbound type vars print as [a b c ...], row vars as [e e1 e2 ...], and skolems by
    their source names. *)
let show ?(name_of = fun h -> String.sub (Hash.to_hex h) 0 8) ?effect_name_of ?(surface = false)
    (t : ty) : string =
  let effect_name_of = Option.value ~default:name_of effect_name_of in
  let tnames : (int, string) Hashtbl.t = Hashtbl.create 8 in
  let rnames : (int, string) Hashtbl.t = Hashtbl.create 8 in
  let tname id =
    match Hashtbl.find_opt tnames id with
    | Some n -> n
    | None ->
        let i = Hashtbl.length tnames in
        let n =
          if i < 26 then String.make 1 (Char.chr (Char.code 'a' + i))
          else Printf.sprintf "a%d" (i - 25)
        in
        Hashtbl.add tnames id n;
        n
  in
  let rname id =
    match Hashtbl.find_opt rnames id with
    | Some n -> n
    | None ->
        let i = Hashtbl.length rnames in
        let n = if i = 0 then "e" else Printf.sprintf "e%d" i in
        Hashtbl.add rnames id n;
        n
  in
  let show_row (r : row) =
    let r = repr_row r in
    let effs = List.map effect_name_of (List.sort Hash.compare r.effects) in
    match r.tail with
    | RClosed -> String.concat ", " effs
    | RVar { contents = RUnbound { id; _ } } ->
        if effs = [] then (if surface then "| " else "") ^ rname id
        else String.concat ", " effs ^ " | " ^ rname id
    | RVar { contents = RLink _ } -> assert false
    | RSkolem (_, n) ->
        if effs = [] then (if surface then "| " else "") ^ n
        else String.concat ", " effs ^ " | " ^ n
  in
  let rec go ~paren t =
    match repr t with
    | TVar { contents = Unbound { id; _ } } -> tname id
    | TVar { contents = Link _ } -> assert false
    | TSkolem (_, n) -> n
    | TCon (h, []) -> name_of h
    | TCon (h, args) ->
        let s = name_of h ^ " " ^ String.concat " " (List.map (go ~paren:true) args) in
        if paren then "(" ^ s ^ ")" else s
    | TTuple [] -> "()"
    | TTuple items -> "(" ^ String.concat ", " (List.map (go ~paren:false) items) ^ ")"
    | TArrow (params, row, result) ->
        let s =
          Printf.sprintf "(%s) ->{%s} %s"
            (String.concat ", " (List.map (go ~paren:false) params))
            (show_row row) (go ~paren:false result)
        in
        if paren then "(" ^ s ^ ")" else s
  in
  go ~paren:false t

(** Render a scheme when anything is quantified. With [surface], row variables occupy the explicit
    [|] namespace required by surface syntax: [forall a | e. TYPE]. Variable naming is shared with
    the body rendering, so quantifier names line up. *)
let show_scheme ?name_of ?effect_name_of ?(surface = false) (s : scheme) : string =
  let tids, rids = quantified s in
  let body = show ?name_of ?effect_name_of ~surface s.ty in
  (* naming in [show] assigns letters in first-appearance order, which matches [quantified]'s
     traversal; reconstruct the quantifier prefix from counts *)
  if tids = [] && rids = [] then body
  else
    let tnames = List.mapi (fun i _ -> String.make 1 (Char.chr (Char.code 'a' + i))) tids in
    let rnames = List.mapi (fun i _ -> if i = 0 then "e" else Printf.sprintf "e%d" i) rids in
    let quantified =
      if (not surface) || rnames = [] then String.concat " " (tnames @ rnames)
      else if tnames = [] then "| " ^ String.concat " " rnames
      else String.concat " " tnames ^ " | " ^ String.concat " " rnames
    in
    "forall " ^ quantified ^ ". " ^ body
