(** The Perceus ownership pass (docs/native-plan.md, task 68; Reinking, Xie, de Moura, Leijen, PLDI
    2021 §2.2-2.4, adapted to NIR).

    Replaces the skeleton's naive discipline (dup every use, drop everything at exit) with precise
    ownership: every owned local is consumed exactly once per path. A variable's LAST use becomes a
    move ([AMove], no dup); a variable that dies without a further use gets an explicit [Drop] at
    its liveness frontier; a pattern variable never used is never bound (rewritten to a wildcard, so
    the emitter skips the dup entirely). The emitter in precise mode emits no exit-point drops of
    its own — this pass owns every count.

    Ownership context: a function owns its parameters, [clo], and every Let/pattern binding.
    Environment slots ([AEnv]) are read through [clo] and always dup on use (the closure owns them);
    globals, statics, and ints are immortal, so moving them is meaningless and they are left
    untouched. *)

open Compile
module SSet = Set.Make (String)

(* vars an atom reads (AMove cannot occur pre-pass) *)
let atom_var = function AVar x -> Some x | _ -> None

(* liveness must also see reads-THROUGH: an AEnv slot is read through [clo], so any AEnv
   occurrence keeps clo alive (dropping clo before an env read was the pass's first bug) *)
let atom_reads = function AVar x -> [ x ] | AEnv _ -> [ "clo" ] | _ -> []

let atoms_free (atoms : atom list) : SSet.t =
  List.fold_left (fun acc a -> SSet.union acc (SSet.of_list (atom_reads a))) SSet.empty atoms

let bound_atoms = function
  | BAtom a -> [ a ]
  | BCallKnown (_, args) | BIntrinsic (_, args) | BAllocTuple args | BAllocCode (_, args) -> args
  | BCallUnknown (f, args) -> f :: args
  | BAllocCon (_, args) | BAllocConReuse (_, args, _) | BPerform (_, args) -> args
  | BAllocClosure { captured; _ } -> captured
  | BHandle (entries, thunk, retc) -> thunk :: retc :: List.map (fun (_, _, a) -> a) entries

let rec free (e : expr) : SSet.t =
  match e with
  | Ret a -> atoms_free [ a ]
  | LetReuse (_, x, _, body) -> SSet.add x (free body)
  | Drop (xs, body) -> List.fold_left (fun acc x -> SSet.add x acc) (free body) xs
  | Let (x, b, body) -> SSet.union (atoms_free (bound_atoms b)) (SSet.remove x (free body))
  | Match (a, clauses) ->
      List.fold_left
        (fun acc (p, body) -> SSet.union acc (SSet.diff (free body) (npat_binds p)))
        (atoms_free [ a ]) clauses
  | TailSelf (args, post) | TailKnown (_, args, post) ->
      SSet.union (atoms_free args) (SSet.of_list post)
  | TailUnknown (f, args, post) -> SSet.union (atoms_free (f :: args)) (SSet.of_list post)

and npat_binds (p : npat) : SSet.t =
  match p with
  | NPWild | NPLit _ -> SSet.empty
  | NPVar x -> SSet.singleton x
  | NPAs (x, inner) -> SSet.add x (npat_binds inner)
  | NPCon (_, ps) | NPTuple ps ->
      List.fold_left (fun acc p -> SSet.union acc (npat_binds p)) SSet.empty ps

(* Rewrite an atom list: the LAST occurrence of each movable var becomes AMove. Occurrences
   are consumed left-to-right at runtime, so the move is the rightmost occurrence. *)
let annotate_atoms (movable : SSet.t) (atoms : atom list) : atom list * SSet.t =
  let moved = ref SSet.empty in
  let rev =
    List.rev_map
      (fun a ->
        match atom_var a with
        | Some x when SSet.mem x movable && not (SSet.mem x !moved) ->
            moved := SSet.add x !moved;
            AMove a
        | _ -> a)
      atoms
  in
  (List.rev rev, !moved)

let annotate_bound (movable : SSet.t) (b : bound) : bound * SSet.t =
  match b with
  | BAtom a ->
      let atoms, moved = annotate_atoms movable [ a ] in
      (BAtom (List.hd atoms), moved)
  | BCallKnown (h, args) ->
      let args, moved = annotate_atoms movable args in
      (BCallKnown (h, args), moved)
  | BCallUnknown (f, args) ->
      let atoms, moved = annotate_atoms movable (f :: args) in
      (BCallUnknown (List.hd atoms, List.tl atoms), moved)
  | BIntrinsic (n, args) ->
      let args, moved = annotate_atoms movable args in
      (BIntrinsic (n, args), moved)
  | BAllocCode (t, args) ->
      let args, moved = annotate_atoms movable args in
      (BAllocCode (t, args), moved)
  | BAllocCon (h, args) ->
      let args, moved = annotate_atoms movable args in
      (BAllocCon (h, args), moved)
  | BAllocConReuse (h, args, tok) ->
      let args, moved = annotate_atoms movable args in
      (BAllocConReuse (h, args, tok), moved)
  | BAllocTuple args ->
      let args, moved = annotate_atoms movable args in
      (BAllocTuple args, moved)
  | BPerform (h, args) ->
      let args, moved = annotate_atoms movable args in
      (BPerform (h, args), moved)
  | BHandle (entries, thunk, retc) ->
      (* entries, thunk, and ret closure are all consumed by the runtime (the driver owns
         the clauses and ret, the call owns the thunk); annotate together, entries first
         like the emitter *)
      let atoms, moved =
        annotate_atoms movable (List.map (fun (_, _, a) -> a) entries @ [ thunk; retc ])
      in
      let rec split acc es ats =
        match (es, ats) with
        | [], [ t; r ] -> (List.rev acc, t, r)
        | (o, c, _) :: es', a :: ats' -> split ((o, c, a) :: acc) es' ats'
        | _ -> assert false
      in
      let entries', thunk', retc' = split [] entries atoms in
      (BHandle (entries', thunk', retc'), moved)
  | BAllocClosure c ->
      (* the self slot's entry is never moved or dup'd (stored as the closure itself) *)
      let movable' =
        match c.self_slot with
        | None -> movable
        | Some i -> (
            match List.nth_opt c.captured i with
            | Some (AVar x) -> SSet.remove x movable
            | _ -> movable)
      in
      let captured, moved = annotate_atoms movable' c.captured in
      (BAllocClosure { c with captured }, moved)

(* Drop dead pattern binders at the source: an unused NPVar becomes NPWild (no dup, no local).
   NPAs keeps its inner pattern; a dead as-binder degrades to the inner pattern alone. *)
let rec prune_pat (used : SSet.t) (p : npat) : npat =
  match p with
  | NPWild | NPLit _ -> p
  | NPVar x -> if SSet.mem x used then p else NPWild
  | NPAs (x, inner) ->
      let inner = prune_pat used inner in
      if SSet.mem x used then NPAs (x, inner) else inner
  | NPCon (h, ps) -> NPCon (h, List.map (prune_pat used) ps)
  | NPTuple ps -> NPTuple (List.map (prune_pat used) ps)

let add_drop xs body = if xs = [] then body else Drop (xs, body)

(* Reuse tokens need unique C names WITHIN a function: the same scrutinee var can be
   re-matched in nested Matches, and a name collision C-shadows the outer token so its
   shell leaks. The counter resets per function so emitted units are byte-stable across
   programs — the cross-program spec cache depends on it (review find, task 69). *)
let tok_counter = ref 0

(* reuse tokens are raw detached shells; a frame suspension between the take
   and its refill would leak or double-release the shell, so framed bodies
   run the precise walk with reuse OFF (task 82) *)
let reuse_enabled = ref true

let fresh_tok x =
  incr tok_counter;
  Printf.sprintf "_tok_%s_%d" x !tok_counter

(* At a tail, every owned local must be consumed: moved vars transfer into the call; the rest
   drop. Anything the arguments read THROUGH (clo, via AEnv) must drop AFTER the argument
   temps are materialized — the emitter runs post-drops between the dups and the call. *)
let split_tail_drops (owned : SSet.t) (moved : SSet.t) (atoms : atom list) :
    string list * string list =
  let d = SSet.diff owned moved in
  let read_through = List.exists (function AEnv _ | AMove (AEnv _) -> true | _ -> false) atoms in
  if read_through && SSet.mem "clo" d then (SSet.elements (SSet.remove "clo" d), [ "clo" ])
  else (SSet.elements d, [])

(* [walk owned e]: [owned] is every live owned local; the result consumes each exactly once on
   every path. *)
let rec walk (owned : SSet.t) (e : expr) : expr =
  match e with
  | Drop _ | LetReuse _ -> e (* never pre-existing *)
  | Ret a -> (
      match a with
      | AVar x when SSet.mem x owned ->
          add_drop (SSet.elements (SSet.remove x owned)) (Ret (AMove a))
      | AEnv _ when SSet.mem "clo" owned ->
          (* the read goes through clo: materialize first, then release everything *)
          Let ("_renv", BAtom a, add_drop (SSet.elements owned) (Ret (AMove (AVar "_renv"))))
      | _ -> add_drop (SSet.elements owned) (Ret a))
  | Let (x, b, body) ->
      let fv_body = SSet.remove x (free body) in
      (* vars whose last use is inside [b] move there; vars dead already drop first *)
      let movable = SSet.diff owned fv_body in
      let b', moved = annotate_bound movable b in
      let dead_before = SSet.diff (SSet.diff owned fv_body) moved in
      (* a bound that reads AEnv reads THROUGH clo: clo cannot die before it *)
      let reads_through = List.exists (function AEnv _ -> true | _ -> false) (bound_atoms b) in
      let clo_late = reads_through && SSet.mem "clo" dead_before in
      let dead_before = if clo_late then SSet.remove "clo" dead_before else dead_before in
      let owned_after = SSet.add x (SSet.inter owned fv_body) in
      let body' =
        if SSet.mem x (free body) then walk owned_after body
        else Drop ([ x ], walk (SSet.remove x owned_after) body)
      in
      let body' = if clo_late then Drop ([ "clo" ], body') else body' in
      add_drop (SSet.elements dead_before) (Let (x, b', body'))
  | Match (a, clauses) ->
      let clauses' =
        List.map
          (fun (p, body) ->
            let fv = free body in
            let used_binds = SSet.inter (npat_binds p) fv in
            let p' = prune_pat used_binds p in
            (* the scrutinee: owned and dead in this clause -> drop at clause head (fields
               were dup'd by the binds, which the emitter runs first) *)
            let scrutinee_dead =
              match atom_var a with
              | Some x -> SSet.mem x owned && not (SSet.mem x fv)
              | None -> false
            in
            (* EVERY owned var flows into every clause: a var live in another arm but
               dead on this one must still be consumed here — the walk drops it at its
               frontier. Intersecting with this clause's fv leaked exactly those. *)
            let owned' =
              SSet.union used_binds
                (match atom_var a with
                | Some x when scrutinee_dead -> SSet.remove x owned
                | _ -> owned)
            in
            let body' = walk owned' body in
            match (p', a) with
            | NPCon (_, ps), AVar x when scrutinee_dead && !reuse_enabled ->
                (* the dying unique CON's shell feeds same-arity allocations here *)
                let arity = List.length ps in
                let tok = fresh_tok x in
                let rec reuse (e : expr) : expr =
                  match e with
                  | Let (y, BAllocCon (h, args), rest) when List.length args = arity ->
                      Let (y, BAllocConReuse (h, args, tok), reuse rest)
                  | Let (y, b, rest) -> Let (y, b, reuse rest)
                  | Drop (xs, rest) -> Drop (xs, reuse rest)
                  | LetReuse (t, s, n, rest) -> LetReuse (t, s, n, reuse rest)
                  | Match (s, cls) -> Match (s, List.map (fun (q, e) -> (q, reuse e)) cls)
                  | Ret _ | TailSelf _ | TailKnown _ | TailUnknown _ -> e
                in
                (p', LetReuse (tok, x, arity, reuse body'))
            | _ ->
                let head_drops =
                  match atom_var a with Some x when scrutinee_dead -> [ x ] | _ -> []
                in
                (p', add_drop head_drops body'))
          clauses
      in
      Match (a, clauses')
  | TailSelf (args, _) ->
      let args', moved = annotate_atoms owned args in
      let pre, post = split_tail_drops owned moved args' in
      add_drop pre (TailSelf (args', post))
  | TailKnown (h, args, _) ->
      let args', moved = annotate_atoms owned args in
      let pre, post = split_tail_drops owned moved args' in
      add_drop pre (TailKnown (h, args', post))
  | TailUnknown (f, args, _) ->
      let atoms', moved = annotate_atoms owned (f :: args) in
      let pre, post = split_tail_drops owned moved atoms' in
      add_drop pre (TailUnknown (List.hd atoms', List.tl atoms', post))

(* Function entry: parameters and [clo] are owned. Parameters bound by irrefutable patterns
   transfer into their pattern locals in the prologue; the emitter models that as: NPVar
   params alias the argument local (no dup), other patterns dup their binds and the argument
   itself stays owned. The pass mirrors exactly that. *)
let reset_tokens () = tok_counter := 0

let fn ?(reuse = true) (f : fn) : fn =
  reset_tokens ();
  reuse_enabled := reuse;
  let param_owned =
    List.mapi
      (fun i p ->
        match p with
        | NPVar x -> [ x ] (* the argument local is renamed into the binder *)
        | NPWild ->
            [ Printf.sprintf "a%d" i ]
            (* a wildcard param still ARRIVES owned; nothing binds it, so the walk must
               drop it at its frontier (map.set's ignore-old-value lambda leaked here) *)
        | _ -> Printf.sprintf "a%d" i :: SSet.elements (npat_binds p))
      f.params
    |> List.concat
  in
  let owned = SSet.add "clo" (SSet.of_list param_owned) in
  let body = walk owned f.body in
  reuse_enabled := true;
  { f with body }
