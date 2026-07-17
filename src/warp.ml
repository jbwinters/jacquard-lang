(** Warp, the testing layer (plan W6.1–W6.3, W6.8).

    Discovery is by CHECKED TYPE (decision D12): a store term whose elaborated type is [test] is a
    hermetic test, [world-test] a world test; names are display only. The hermetic lane runs each
    thunk under the in-language [test.run] handler through {!Round_robin.run_call}, so a scoped
    Async lifecycle uses the same deterministic evaluator driver as the CLI; the world lane runs
    only tests whose row the CLI's grants cover, refusing the rest by name.

    The result cache (W6.3) is an honest lookup table over the Merkle discipline: a Case's key is
    its member hash (which covers its transitive references), a Prop's key adds mode/samples/seed
    from day one, WorldTests are never cached. Every key includes {!version} — native drivers live
    in no hash, so the explicit tag re-keys the world when they change. Entries are canonical
    printed forms; a corrupt entry is ignored and rerun.

    Coverage (W6.8) is the complement of the union of per-test {!Eval.ctx} coverage sets —
    definition-level, from the hash discipline alone; cache entries record their coverage so a
    fully-cached run reports the same complement as a cold one. *)

let version = "warp-v1"

type verdict = Pass of int | Fail of { soft : string list; hard : string option } | NoChecks

type outcome = {
  display : string;
  verdict : verdict option;  (** None = skipped (prop pending) or refused *)
  note : string option;  (** SKIP/REFUSED annotation *)
  coverage : Hash.t list;
  cached : bool;
}

type discovered = Hermetic of string * Hash.t | World of string * Hash.t

(** how the prop lane runs: seeded sampling with shrinking (W6.4) or exhaustive enumeration under a
    branch budget (W6.5) *)
type prop_mode = Sampling of { seed : int; samples : int } | Exhaustive of { budget : int }

type schedule_plan =
  | Default_schedule
  | Seeded_schedules of { seed : int; schedules : int; replay_command : string }
      (** A Warp Case normally uses the fixed FIFO scheduler. [Seeded_schedules] reruns each
          hermetic Case under reproducible SplitMix64 decisions. The root seed is mixed with the
          canonical member hash and relative leaf path, so discovery order, top-level renames, and
          cache hits cannot change another test's schedule stream. *)

(* --- discovery (W6.2) --- *)

let discover (store : Store.t) (cctx : Check.ctx) : discovered list =
  let ty_hash name =
    match Store.lookup_kind store name Resolve.KType with
    | Some { Resolve.hash; _ } -> Some hash
    | None -> None
  in
  match (ty_hash "test", ty_hash "world-test") with
  | Some test_h, Some world_h ->
      List.filter_map
        (fun (name, { Resolve.hash; kind }) ->
          if kind <> Resolve.KTerm then None
          else
            match Types.repr (Check.term_scheme cctx hash).Types.ty with
            | exception Check.Err _ -> None (* unschemable => not a test *)
            | Types.TCon (h, []) when Hash.equal h test_h -> Some (Hermetic (name, hash))
            | Types.TCon (h, []) when Hash.equal h world_h -> Some (World (name, hash))
            | _ -> None)
        (List.sort (fun (a, _) (b, _) -> String.compare a b) (Store.names store))
  | _ -> []

(* --- running (W6.2) --- *)

let value_of ctx (h : Hash.t) : (Value.t, Runtime_err.t) result =
  Round_robin.run_expr ctx { Kernel.it = Kernel.Ref (h, Kernel.Term); meta = Meta.empty }

(* decompose a runtime report; the shape is pinned by prelude/15-warp.jqd *)
let verdict_of_report (v : Value.t) : (verdict, string) result =
  let rec entries acc = function
    | Value.VCon { name = "nil"; _ } -> Ok (List.rev acc)
    | Value.VCon
        {
          name = "cons";
          args = [ Value.VTuple [ Value.VText label; Value.VCon { name = ok; _ } ]; rest ];
          _;
        } ->
        entries ((label, ok = "true") :: acc) rest
    | v -> Error (Printf.sprintf "malformed report entries: %s" (Value.show v))
  in
  match v with
  | Value.VCon { name = "mk-report"; args = [ es; hard ]; _ } -> (
      match entries [] es with
      | Error e -> Error e
      | Ok es -> (
          let soft = List.filter_map (fun (l, ok) -> if ok then None else Some l) es in
          match hard with
          | Value.VCon { name = "some"; args = [ Value.VText msg ]; _ } ->
              Ok (Fail { soft; hard = Some msg })
          | Value.VCon { name = "none"; _ } ->
              if soft <> [] then Ok (Fail { soft; hard = None })
              else if es = [] then Ok NoChecks
              else Ok (Pass (List.length es))
          | v -> Error (Printf.sprintf "malformed report hard field: %s" (Value.show v))))
  | v -> Error (Printf.sprintf "not a report: %s" (Value.show v))

(* Run one thunk under test.run, collecting its per-test coverage set. A runtime crash
   is a FAILING verdict, not a runner abort: one broken test must not blind the suite.
   NOTE (coverage approximation, documented): ctx.memo persists across tests, so a
   computed CONSTANT's transitive deps mark only the first test that forces it; later
   tests record the constant itself but not what it touched. Safe direction only — a
   warm complement can over-report "uncovered", never falsely claim covered. *)
let run_thunk ctx ~test_run (thunk : Value.t) : (verdict * Hash.t list, string) result =
  let result, mine =
    Eval.with_fresh_coverage ctx (fun () -> Round_robin.run_call ctx test_run [ thunk ])
  in
  match result with
  | Ok report -> Result.map (fun v -> (v, mine)) (verdict_of_report report)
  | Error e ->
      Ok (Fail { soft = []; hard = Some ("runtime error: " ^ Runtime_err.to_string e) }, mine)

let schedule_identity_version = "warp-schedule-leaf-v1"

let add_schedule_identity_frame buffer value =
  Printf.bprintf buffer "%d:" (String.length value);
  Buffer.add_string buffer value

(** [schedule_leaf_identity ~member ~relative_path ~structural_path] binds one scheduled Case to its
    Merkle member, length-framed relative labels, and zero-based structural child-index path. The
    framing is injective even when labels contain NUL bytes, while the index path distinguishes
    duplicate labels without depending on the renameable top-level display name. *)
let schedule_leaf_identity ~member ~relative_path ~structural_path =
  if List.exists (fun index -> index < 0) structural_path then
    invalid_arg "Warp.schedule_leaf_identity: structural indices must be non-negative";
  let buffer = Buffer.create 160 in
  let frame = add_schedule_identity_frame buffer in
  frame schedule_identity_version;
  frame (Hash.to_hex member);
  frame "labels";
  frame (string_of_int (List.length relative_path));
  List.iter frame relative_path;
  frame "indices";
  frame (string_of_int (List.length structural_path));
  List.iter (fun index -> frame (string_of_int index)) structural_path;
  Hash.of_string (Buffer.contents buffer)

(** [schedule_test_seed] derives a leaf-local SplitMix64 seed from the root seed and the complete
    framed structural identity used by schedule traces. *)
let schedule_test_seed ~seed ~member ~relative_path ~structural_path =
  let identity = schedule_leaf_identity ~member ~relative_path ~structural_path |> Hash.to_hex in
  let identity_bits = int_of_string ("0x" ^ String.sub identity 0 14) in
  let rng = Infer_dist.Rng.make (seed lxor identity_bits) in
  Int64.to_int (Infer_dist.Rng.next_int64 rng)

let add_coverage accumulated current = List.sort_uniq Hash.compare (current @ accumulated)

let schedule_failure ~seed ~index ~schedules ~replay_command schedule verdict =
  let prefix =
    Printf.sprintf
      "random schedule %d of %d failed (decision seed %d)\nreplay: %s\nschedule log:\n%s"
      (index + 1) schedules seed replay_command
      (Schedule_trace.serialize schedule)
  in
  match verdict with
  | Fail { soft; hard } ->
      Fail
        {
          soft;
          hard =
            Some (prefix ^ Option.fold ~none:"" ~some:(fun detail -> "failure:\n" ^ detail) hard);
        }
  | Pass _ | NoChecks -> verdict

let run_thunk_seeded ctx ?(bounds = Round_robin.default_bounds) ~test_run ~program ~root_seed
    ~test_seed ~schedules ~replay_command (thunk : Value.t) :
    (verdict * Hash.t list * string option, string) result =
  let master = Infer_dist.Rng.make test_seed in
  let rec run index coverage last_verdict =
    if index >= schedules then
      Ok
        ( Option.value ~default:NoChecks last_verdict,
          coverage,
          Some (Printf.sprintf "schedules: %d, seed %d" schedules root_seed) )
    else
      let decision_seed =
        if index = 0 then test_seed else Int64.to_int (Infer_dist.Rng.next_int64 master)
      in
      let result, mine =
        Eval.with_fresh_coverage ctx (fun () ->
            Round_robin.run_call_recorded ctx ~bounds ~program
              ~mode:(Round_robin.Seeded_schedule { seed = decision_seed })
              test_run [ thunk ])
      in
      let coverage = add_coverage coverage mine in
      match result with
      | Error error ->
          Ok
            ( Fail
                {
                  soft = [];
                  hard =
                    Some
                      (Printf.sprintf
                         "random schedule %d of %d refused before a complete trace (decision seed \
                          %d)\n\
                          replay: %s\n\
                          runtime error: %s"
                         (index + 1) schedules decision_seed replay_command
                         (Runtime_err.to_string error));
                },
              coverage,
              Some
                (Printf.sprintf "schedule: failed %d/%d, seed %d" (index + 1) schedules root_seed)
            )
      | Ok { Round_robin.result = Error error; schedule; _ } ->
          Ok
            ( Fail
                {
                  soft = [];
                  hard =
                    Some
                      (Printf.sprintf
                         "random schedule %d of %d failed (decision seed %d)\n\
                          replay: %s\n\
                          schedule log:\n\
                          %sruntime error: %s"
                         (index + 1) schedules decision_seed replay_command
                         (Schedule_trace.serialize schedule)
                         (Runtime_err.to_string error));
                },
              coverage,
              Some
                (Printf.sprintf "schedule: failed %d/%d, seed %d" (index + 1) schedules root_seed)
            )
      | Ok { Round_robin.result = Ok value; schedule; _ } -> (
          match verdict_of_report value with
          | Error error -> Error error
          | Ok (Fail _ as verdict) ->
              Ok
                ( schedule_failure ~seed:decision_seed ~index ~schedules ~replay_command schedule
                    verdict,
                  coverage,
                  Some
                    (Printf.sprintf "schedule: failed %d/%d, seed %d" (index + 1) schedules
                       root_seed) )
          | Ok NoChecks -> run (index + 1) coverage (Some NoChecks)
          | Ok (Pass _ as verdict) ->
              let verdict = match last_verdict with Some NoChecks -> NoChecks | _ -> verdict in
              run (index + 1) coverage (Some verdict))
  in
  run 0 [] None

(* the world row a wcase thunk needs, read from the constructor's own scheme *)
let world_required (cctx : Check.ctx) (store : Store.t) : Hash.t list =
  match Store.lookup_kind store "wcase" Resolve.KCon with
  | None -> []
  | Some { Resolve.hash; _ } -> (
      match Types.repr (Check.con_scheme cctx hash).Types.ty with
      | Types.TArrow ([ _label; thunk_ty ], _, _) -> (
          match Types.repr thunk_ty with
          | Types.TArrow ([], row, _) ->
              let row = Types.repr_row row in
              let check_h =
                match Store.lookup_kind store "check" Resolve.KEffect with
                | Some { Resolve.hash; _ } -> Some hash
                | None -> None
              in
              List.filter
                (fun h -> match check_h with Some c -> not (Hash.equal h c) | None -> true)
                row.Types.effects
          | _ -> [])
      | _ -> [])

(* --- property lanes (W6.4 sampling + choice-log shrinking, W6.5 exhaustive) --- *)

(* One logged random choice: the distribution at the site plus the OUTCOME INDEX in
   shrink order — smaller index = simpler. Bernoulli maps 0=false/1=true (so "toward
   false" is index-lowering, like uniform-int toward lo and categorical toward earlier
   entries); uniform-int index i is lo+i; categorical indexes its entry list. *)
type choice = { c_dist : Infer_dist.dist_v; c_index : int }

let choice_arity (d : Infer_dist.dist_v) : int =
  match d with
  | Infer_dist.Bernoulli _ -> 2
  | Infer_dist.UniformInt (lo, hi) -> hi - lo + 1
  | Infer_dist.Categorical entries -> List.length entries

let choice_value ctx (d : Infer_dist.dist_v) (i : int) : (Value.t, Runtime_err.t) result =
  match d with
  | Infer_dist.UniformInt (lo, _) -> Ok (Value.VInt (lo + i))
  | Infer_dist.Categorical entries -> Ok (fst (List.nth entries i))
  | Infer_dist.Bernoulli _ -> (
      match
        ( Store.lookup_kind (Eval.store ctx) "true" Resolve.KCon,
          Store.lookup_kind (Eval.store ctx) "false" Resolve.KCon )
      with
      | Some { Resolve.hash = t; _ }, Some { Resolve.hash = f; _ } ->
          if i = 0 then Ok (Value.VCon { con = f; name = "false"; args = [] })
          else Ok (Value.VCon { con = t; name = "true"; args = [] })
      | _ -> Error (Runtime_err.Unresolved "prelude bool constructors"))

let fresh_index rng (d : Infer_dist.dist_v) : int =
  match d with
  | Infer_dist.Bernoulli p -> if Infer_dist.Rng.float rng < p then 1 else 0
  | Infer_dist.UniformInt (lo, hi) ->
      int_of_float (Infer_dist.Rng.float rng *. float_of_int (hi - lo + 1))
  | Infer_dist.Categorical entries ->
      let total = List.fold_left (fun acc (_, p) -> acc +. p) 0.0 entries in
      let u = Infer_dist.Rng.float rng *. if total > 0.0 then total else 1.0 in
      let rec go i acc = function
        | [] -> max 0 (List.length entries - 1)
        | (_, p) :: rest -> if u < acc +. p then i else go (i + 1) (acc +. p) rest
      in
      go 0 0.0 entries

type prop_run = { pr_verdict : verdict; pr_log : choice list }

(* Drive one property execution. check/fail are handled NATIVELY in this lane so the
   choice log and the report interleave correctly (nesting test.run would swallow the
   check ops before the driver sees them — decided, documented). [forced] replays a
   log positionally; running past its end samples fresh; a forced index that does not
   fit the site's distribution is DIVERGENCE (`Error \`Diverged`), which the shrinker
   skips and the generator-validity theorem test asserts never happens. *)
let drive_prop ctx ~rng ~(forced : int list) (thunk : Value.t) :
    (prop_run, [ `Diverged | `Runtime of string ]) result =
  let log = ref [] in
  let entries = ref [] in
  let rec go state forced =
    match Eval.run_state_capturing ctx state with
    | Error e -> Error (`Runtime (Runtime_err.to_string e))
    | Ok (Eval.CValue _) ->
        let es = List.rev !entries in
        let soft = List.filter_map (fun (l, ok) -> if ok then None else Some l) es in
        let v =
          if soft <> [] then Fail { soft; hard = None }
          else if es = [] then NoChecks
          else Pass (List.length es)
        in
        Ok { pr_verdict = v; pr_log = List.rev !log }
    | Ok (Eval.COp { name = "sample"; args = [ dv ]; kont; _ }) -> (
        match Infer_dist.dist_of_value ctx dv with
        | Error e -> Error (`Runtime (Runtime_err.to_string e))
        | Ok d -> (
            let arity = choice_arity d in
            let pick, rest =
              match forced with
              | i :: rest -> ((if i < arity then Some i else None), rest)
              | [] -> (Some (fresh_index rng d), [])
            in
            match pick with
            | None -> Error `Diverged
            | Some i -> (
                match choice_value ctx d i with
                | Error e -> Error (`Runtime (Runtime_err.to_string e))
                | Ok v -> (
                    log := { c_dist = d; c_index = i } :: !log;
                    match Eval.resume_captured_state ctx kont v with
                    | Error e -> Error (`Runtime (Runtime_err.to_string e))
                    | Ok state -> go state rest))))
    | Ok (Eval.COp { name = "observe"; args = [ _; _ ]; kont; _ }) -> (
        (* sampling lane: conditioning is ignored (weights are an enumeration
               concept); the exhaustive lane scales branches properly *)
        match Eval.resume_captured_state ctx kont Value.unit_v with
        | Error e -> Error (`Runtime (Runtime_err.to_string e))
        | Ok state -> go state forced)
    | Ok
        (Eval.COp
           { name = "check"; args = [ Value.VCon { name = ok; _ }; Value.VText label ]; kont; _ })
      -> (
        entries := (label, ok = "true") :: !entries;
        match Eval.resume_captured_state ctx kont Value.unit_v with
        | Error e -> Error (`Runtime (Runtime_err.to_string e))
        | Ok state -> go state forced)
    | Ok (Eval.COp { name = "fail"; args = [ Value.VText msg ]; _ }) ->
        let es = List.rev !entries in
        let soft = List.filter_map (fun (l, ok) -> if ok then None else Some l) es in
        Ok { pr_verdict = Fail { soft; hard = Some msg }; pr_log = List.rev !log }
    | Ok (Eval.COp { name; _ }) -> Error (`Runtime ("prop performed unhandled op " ^ name))
  in
  go (Eval.apply_state ctx thunk []) forced

let is_fail = function Fail _ -> true | _ -> false

(* simpler = shorter log, then lexicographically lower indices *)
let simpler (a : choice list) (b : choice list) : bool =
  let la = List.length a and lb = List.length b in
  if la <> lb then la < lb
  else
    let rec lex = function
      | [], [] -> false
      | x :: xs, y :: ys -> if x.c_index <> y.c_index then x.c_index < y.c_index else lex (xs, ys)
      | _ -> false
    in
    lex (a, b)

(* Candidate edits in fixed priority: contiguous-span deletion (longest spans first —
   the list-length choice disappearing IS list shrinking), then one-step index
   lowering. Every candidate replays through the generator itself. *)
let shrink_candidates (log : choice list) : int list list =
  let idx = List.map (fun c -> c.c_index) log in
  let n = List.length idx in
  let deletions =
    List.concat_map
      (fun len ->
        List.filter_map
          (fun start ->
            if start + len <= n then
              Some (List.filteri (fun i _ -> i < start || i >= start + len) idx)
            else None)
          (List.init n Fun.id))
      (List.init n (fun i -> n - i))
  in
  let lowerings =
    List.filter_map
      (fun pos ->
        if (List.nth log pos).c_index > 0 then
          Some (List.mapi (fun i x -> if i = pos then x - 1 else x) idx)
        else None)
      (List.init n Fun.id)
  in
  deletions @ lowerings

(** [shrink ctx ~rng thunk failing] greedily minimizes a failing run's choice log; returns the
    minimal failing run plus the count of diverged candidates (the generator-validity theorem: zero
    across the battery). *)
let shrink ctx ~rng (thunk : Value.t) (failing : prop_run) : prop_run * int =
  let diverged = ref 0 in
  let rec loop current =
    let try_candidate best cand =
      match best with
      | Some _ -> best
      | None -> (
          match drive_prop ctx ~rng ~forced:cand thunk with
          | Error `Diverged ->
              incr diverged;
              None
          | Error (`Runtime _) -> None
          | Ok run ->
              if is_fail run.pr_verdict && simpler run.pr_log current.pr_log then Some run else None
          )
    in
    match List.fold_left try_candidate None (shrink_candidates current.pr_log) with
    | Some better -> loop better
    | None -> current
  in
  (loop failing, !diverged)

(** [run_prop_sampling ctx ~seed ~samples thunk] — N iterations, fresh split per case, first failure
    shrunk greedily. *)
let run_prop_sampling ctx ~seed ~samples (thunk : Value.t) : (verdict * string, string) result =
  let master = Infer_dist.Rng.make seed in
  let rec cases i =
    if i >= samples then Ok (Pass samples, Printf.sprintf "prop: %d cases, seed %d" samples seed)
    else
      let rng = Infer_dist.Rng.split master in
      match drive_prop ctx ~rng ~forced:[] thunk with
      | Error `Diverged -> Error "unforced run cannot diverge"
      | Error (`Runtime e) -> Error e
      | Ok run ->
          if is_fail run.pr_verdict then begin
            let minimal, _ = shrink ctx ~rng thunk run in
            Ok
              ( minimal.pr_verdict,
                Printf.sprintf
                  "prop: falsified on case %d of %d, seed %d; shrunk to %d choice%s [%s]" (i + 1)
                  samples seed (List.length minimal.pr_log)
                  (if List.length minimal.pr_log = 1 then "" else "s")
                  (String.concat ";" (List.map (fun c -> string_of_int c.c_index) minimal.pr_log))
              )
          end
          else cases (i + 1)
  in
  cases 0

(** [run_prop_exhaustive ctx ~budget thunk] — the M3 thesis as a product feature: the multi-shot
    machinery explores every support element at every sample site. Verified branches are weight>0
    completions; zero-weight branches prune without counting. Blowing the budget is a clean refusal
    (E0905), never a partial pass. *)
let run_prop_exhaustive ctx ~budget (thunk : Value.t) : (verdict * string, Diag.t) result =
  let verified = ref 0 in
  let branches = ref 0 in
  let last_site = ref "the property body" in
  let failure = ref None in
  let exception Budget of string in
  let rec explore state weight entries =
    if !failure <> None then Ok ()
    else if weight = 0.0 then Ok () (* pruned: not verified *)
    else (
      incr branches;
      if !branches > budget then
        raise
          (Budget
             (Printf.sprintf "%d explorations (cap %d), last at %s" !branches budget !last_site));
      match Eval.run_state_capturing ctx state with
      | Error e -> Error (Runtime_err.to_string e)
      | Ok (Eval.CValue _) ->
          incr verified;
          let es = List.rev entries in
          let soft = List.filter_map (fun (l, ok) -> if ok then None else Some l) es in
          if soft <> [] then failure := Some (Fail { soft; hard = None });
          Ok ()
      | Ok (Eval.COp { name = "sample"; args = [ dv ]; kont; _ }) -> (
          match
            Result.bind (Infer_dist.dist_of_value ctx dv) (fun d -> Infer_dist.support ctx d)
          with
          | Error e -> Error (Runtime_err.to_string e)
          | Ok support ->
              last_site := Printf.sprintf "a %d-way sample site" (List.length support);
              let rec go = function
                | [] -> Ok ()
                | (v, p) :: rest -> (
                    match Eval.resume_captured_state ctx kont v with
                    | Error e -> Error (Runtime_err.to_string e)
                    | Ok state -> (
                        match explore state (weight *. p) entries with
                        | Error e -> Error e
                        | Ok () -> go rest))
              in
              go support)
      | Ok (Eval.COp { name = "observe"; args = [ dv; v ]; kont; _ }) -> (
          match Result.bind (Infer_dist.dist_of_value ctx dv) (fun d -> Infer_dist.pmf ctx d v) with
          | Error e -> Error (Runtime_err.to_string e)
          | Ok p -> (
              match Eval.resume_captured_state ctx kont Value.unit_v with
              | Error e -> Error (Runtime_err.to_string e)
              | Ok state -> explore state (weight *. p) entries))
      | Ok
          (Eval.COp
             { name = "check"; args = [ Value.VCon { name = ok; _ }; Value.VText label ]; kont; _ })
        -> (
          match Eval.resume_captured_state ctx kont Value.unit_v with
          | Error e -> Error (Runtime_err.to_string e)
          | Ok state -> explore state weight ((label, ok = "true") :: entries))
      | Ok (Eval.COp { name = "fail"; args = [ Value.VText msg ]; _ }) ->
          let es = List.rev entries in
          let soft = List.filter_map (fun (l, ok) -> if ok then None else Some l) es in
          failure := Some (Fail { soft; hard = Some msg });
          Ok ()
      | Ok (Eval.COp { name; _ }) -> Error ("prop performed unhandled op " ^ name))
  in
  match explore (Eval.apply_state ctx thunk []) 1.0 [] with
  | exception Budget site ->
      Error
        (Diag.error ~code:"E0905"
           (Printf.sprintf
              "exhaustive verification exceeded its budget: %s; raise --budget or shrink the \
               generators"
              site))
  | Error e -> Error (Diag.error ~code:"E0902" e)
  | Ok () -> (
      match !failure with
      | Some v -> Ok (v, "prop: falsified exhaustively")
      | None ->
          Ok
            ( Pass !verified,
              Printf.sprintf "verified exhaustively (%d case%s)" !verified
                (if !verified = 1 then "" else "s") ))

(* --- the cache (W6.3) --- *)

let cache_key_string = function
  | Hermetic (_, h) -> Printf.sprintf "%s|case|%s" version (Hash.to_hex h)
  | World _ -> invalid_arg "world tests are never cached"

(* prop keys carry mode/samples/seed from day one so the format never migrates *)
let prop_key_string ~member ~mode ~samples ~seed =
  Printf.sprintf "%s|prop|%s|mode=%s|samples=%d|seed=%d" version (Hash.to_hex member) mode samples
    seed

let schedule_key_string ~base ~schedules ~seed =
  Printf.sprintf "%s|scheduler=%s|schedule-identity=%s|schedules=%d|schedule-seed=%d" base
    Round_robin.seeded_scheduler_version schedule_identity_version schedules seed

let verdict_form (verdict : verdict) : Form.t =
  match verdict with
  | Pass n -> Form.form "pass" [ Form.Int n ]
  | NoChecks -> Form.form "no-checks" []
  | Fail { soft; hard } ->
      Form.form "fail"
        (Form.F (Form.form "soft" (List.map (fun s -> Form.Text s) soft))
        :: (match hard with Some h -> [ Form.F (Form.form "hard" [ Form.Text h ]) ] | None -> []))

(* one entry per DISCOVERED test: a group's entry (keyed by the group hash, which
   Merkle-covers every member) holds one outcome per member, display included, so a
   cached hit renders exactly what the cold run rendered *)
let entry_form ~key ~(outcomes : (string * verdict * string option * Hash.t list) list) : Form.t =
  Form.form "test-cache-entry"
    (Form.F (Form.form "key" [ Form.Text key ])
    :: List.map
         (fun (display, verdict, note, coverage) ->
           Form.F
             (Form.form "outcome"
                ([
                   Form.F (Form.form "display" [ Form.Text display ]);
                   Form.F (Form.form "verdict" [ Form.F (verdict_form verdict) ]);
                   Form.F (Form.form "coverage" (List.map (fun h -> Form.Hash h) coverage));
                 ]
                @
                match note with
                | Some n -> [ Form.F (Form.form "note" [ Form.Text n ]) ]
                | None -> [])))
         outcomes)

let verdict_of_form (v : Form.t) : verdict option =
  match v with
  | { Form.head = "pass"; args = [ Form.Int n ]; _ } -> Some (Pass n)
  | { Form.head = "no-checks"; args = []; _ } -> Some NoChecks
  | { Form.head = "fail"; args = Form.F { Form.head = "soft"; args = soft; _ } :: rest; _ } ->
      let soft = List.filter_map (function Form.Text s -> Some s | _ -> None) soft in
      let hard =
        match rest with
        | [ Form.F { Form.head = "hard"; args = [ Form.Text h ]; _ } ] -> Some h
        | _ -> None
      in
      Some (Fail { soft; hard })
  | _ -> None

let entry_of_form (f : Form.t) :
    (string * (string * verdict * string option * Hash.t list) list) option =
  match f with
  | {
   Form.head = "test-cache-entry";
   args = Form.F { Form.head = "key"; args = [ Form.Text key ]; _ } :: rest;
   _;
  } ->
      let outcome = function
        | Form.F
            {
              Form.head = "outcome";
              args =
                Form.F { Form.head = "display"; args = [ Form.Text display ]; _ }
                :: Form.F { Form.head = "verdict"; args = [ Form.F v ]; _ }
                :: Form.F { Form.head = "coverage"; args = cov; _ }
                :: note_rest;
              _;
            } ->
            let note =
              match note_rest with
              | [ Form.F { Form.head = "note"; args = [ Form.Text n ]; _ } ] -> Some n
              | _ -> None
            in
            Option.map
              (fun verdict ->
                ( display,
                  verdict,
                  note,
                  List.filter_map (function Form.Hash h -> Some h | _ -> None) cov ))
              (verdict_of_form v)
        | _ -> None
      in
      let outcomes = List.map outcome rest in
      if List.exists (( = ) None) outcomes then None else Some (key, List.filter_map Fun.id outcomes)
  | _ -> None

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let cache_lookup ~cache_dir key : (string * verdict * string option * Hash.t list) list option =
  match cache_dir with
  | None -> None
  | Some dir -> (
      let path = Filename.concat dir (Hash.to_hex (Hash.of_string key) ^ ".jqd") in
      match read_file path with
      | exception Sys_error _ -> None (* absent or unreadable: rerun *)
      | src -> (
          match Reader.parse_one ~file:path src with
          | Ok f -> (
              match entry_of_form f with
              | Some (k, outcomes) when k = key && outcomes <> [] -> Some outcomes
              | _ -> None (* corrupt or mismatched: ignore and rerun *))
          | Error _ -> None))

let cache_store ~cache_dir key outcomes : unit =
  match cache_dir with
  | None -> ()
  | Some dir -> (
      try
        if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
        let path = Filename.concat dir (Hash.to_hex (Hash.of_string key) ^ ".jqd") in
        let oc = open_out_bin path in
        output_string oc (Printer.print (entry_form ~key ~outcomes) ^ "\n");
        close_out oc
      with Sys_error m -> Printf.eprintf "test-cache unavailable (%s)\n%!" m)

(* --- the runner --- *)

type totals = {
  mutable passed : int;
  mutable failed : int;
  mutable skipped : int;
  mutable refused : int;
  mutable hits : int;
  mutable ran : int;
}

(* does a test value contain a prop anywhere? (drives cache-key choice) *)
let rec value_has_prop (v : Value.t) : bool =
  match v with
  | Value.VCon { name = "prop"; _ } -> true
  | Value.VCon { name = "group"; args = [ _; tests ]; _ } ->
      let rec walk = function
        | Value.VCon { name = "cons"; args = [ t; rest ]; _ } -> value_has_prop t || walk rest
        | _ -> false
      in
      walk tests
  | _ -> false

(* per-test coverage collection around a driver call (same swap as run_thunk) *)
let with_coverage ctx f = Eval.with_fresh_coverage ctx f

(* walk one discovered test VALUE, recursing into groups *)
let rec run_value ctx ~test_run ~prop_mode ~schedule_plan ~member ~schedule_path ~structural_path
    ~display (v : Value.t) : (outcome list, string) result =
  match v with
  | Value.VCon { name = "case"; args = [ Value.VText label; thunk ]; _ } -> (
      let display = display ^ "/" ^ label in
      let schedule_path = schedule_path @ [ label ] in
      let run =
        match schedule_plan with
        | Default_schedule ->
            Result.map (fun (v, c) -> (v, c, None)) (run_thunk ctx ~test_run thunk)
        | Seeded_schedules { seed; schedules; replay_command } ->
            let program =
              schedule_leaf_identity ~member ~relative_path:schedule_path ~structural_path
            in
            let test_seed =
              schedule_test_seed ~seed ~member ~relative_path:schedule_path ~structural_path
            in
            run_thunk_seeded ctx ~test_run ~program ~root_seed:seed ~test_seed ~schedules
              ~replay_command thunk
      in
      match run with
      | Ok (verdict, coverage, note) ->
          Ok [ { display; verdict = Some verdict; note; coverage; cached = false } ]
      | Error e -> Error (Printf.sprintf "%s: %s" display e))
  | Value.VCon { name = "prop"; args = [ Value.VText label; thunk ]; _ } -> (
      let display = display ^ "/" ^ label in
      match prop_mode with
      | Sampling { seed; samples } -> (
          let result, coverage =
            with_coverage ctx (fun () -> run_prop_sampling ctx ~seed ~samples thunk)
          in
          match result with
          | Ok (verdict, note) ->
              Ok [ { display; verdict = Some verdict; note = Some note; coverage; cached = false } ]
          | Error e -> Error (Printf.sprintf "%s: %s" display e))
      | Exhaustive { budget } -> (
          let result, coverage =
            with_coverage ctx (fun () -> run_prop_exhaustive ctx ~budget thunk)
          in
          match result with
          | Ok (verdict, note) ->
              Ok [ { display; verdict = Some verdict; note = Some note; coverage; cached = false } ]
          | Error d ->
              (* budget refusal: a clean catalogued diagnostic that FAILS the test —
                 partial exhaustiveness must never pose as a proof *)
              Ok
                [
                  {
                    display;
                    verdict = Some (Fail { soft = []; hard = Some (Diag.to_string d) });
                    note = Some "prop: exhaustive refusal";
                    coverage;
                    cached = false;
                  };
                ]))
  | Value.VCon { name = "group"; args = [ Value.VText label; tests ]; _ } ->
      let rec walk child_index acc = function
        | Value.VCon { name = "nil"; _ } -> Ok (List.concat (List.rev acc))
        | Value.VCon { name = "cons"; args = [ t; rest ]; _ } -> (
            match
              run_value ctx ~test_run ~prop_mode ~schedule_plan ~member
                ~schedule_path:(schedule_path @ [ label ])
                ~structural_path:(structural_path @ [ child_index ])
                ~display:(display ^ "/" ^ label)
                t
            with
            | Ok os -> walk (child_index + 1) (os :: acc) rest
            | Error e -> Error e)
        | v -> Error (Printf.sprintf "malformed group: %s" (Value.show v))
      in
      walk 0 [] tests
  | Value.VCon { name = "wcase"; args = [ Value.VText label; thunk ]; _ } -> (
      (* world lane: the caller already verified grants; never cached *)
      let display = display ^ "/" ^ label in
      match run_thunk ctx ~test_run thunk with
      | Ok (verdict, coverage) ->
          Ok [ { display; verdict = Some verdict; note = None; coverage; cached = false } ]
      | Error e -> Error (Printf.sprintf "%s: %s" display e))
  | v -> Error (Printf.sprintf "not a test value: %s" (Value.show v))

(** [run_discovered ctx ~test_run ~cache_dir ~granted d] executes one discovered test. Hermetic
    Cases consult the cache by member hash; groups cache as a unit under the group's member hash
    (its hash covers the members). World tests check grant coverage. *)
let run_discovered ctx (cctx : Check.ctx) ~test_run ~prop_mode ~schedule_plan ~cache_dir
    ~(granted : Hash.t list) (d : discovered) : (outcome list, string) result =
  match d with
  | Hermetic (name, h) -> (
      match value_of ctx h with
      | Error e -> Error (Printf.sprintf "%s: %s" name (Runtime_err.to_string e))
      | Ok v -> (
          (* a term whose value contains a prop keys by (hash, mode, samples, seed) —
             the run parameters are part of what the entry means; pure-case terms key
             by member hash alone *)
          let base_key =
            if value_has_prop v then
              match prop_mode with
              | Sampling { seed; samples } ->
                  prop_key_string ~member:h ~mode:"sample" ~samples ~seed
              | Exhaustive _ -> prop_key_string ~member:h ~mode:"exhaustive" ~samples:0 ~seed:0
            else cache_key_string d
          in
          let key =
            match schedule_plan with
            | Default_schedule -> base_key
            | Seeded_schedules { seed; schedules; _ } ->
                schedule_key_string ~base:base_key ~schedules ~seed
          in
          let cached = cache_lookup ~cache_dir key in
          let cached =
            match (schedule_plan, cached) with
            | Seeded_schedules _, Some stored
              when List.exists
                     (fun (_, verdict, _, _) -> match verdict with Fail _ -> true | _ -> false)
                     stored ->
                None
            | _, cached -> cached
          in
          match cached with
          | Some stored ->
              let current_display stored_display =
                match String.index_opt stored_display '/' with
                | Some separator ->
                    name
                    ^ String.sub stored_display separator (String.length stored_display - separator)
                | None -> name
              in
              Ok
                (List.map
                   (fun (display, verdict, note, coverage) ->
                     {
                       display = current_display display;
                       verdict = Some verdict;
                       note;
                       coverage;
                       cached = true;
                     })
                   stored)
          | None -> (
              match
                run_value ctx ~test_run ~prop_mode ~schedule_plan ~member:h ~schedule_path:[]
                  ~structural_path:[ 0 ] ~display:name v
              with
              | Error e -> Error e
              | Ok outcomes ->
                  (* every EXECUTED outcome caches, display and note included, keyed by
                     this test's member hash (a group hash Merkle-covers its members) *)
                  let cacheable =
                    match schedule_plan with
                    | Default_schedule -> List.for_all (fun o -> o.verdict <> None) outcomes
                    | Seeded_schedules _ ->
                        List.for_all
                          (fun o ->
                            match o.verdict with
                            | Some (Pass _ | NoChecks) -> true
                            | Some (Fail _) | None -> false)
                          outcomes
                  in
                  if cacheable && outcomes <> [] then
                    cache_store ~cache_dir key
                      (List.map
                         (fun o -> (o.display, Option.get o.verdict, o.note, o.coverage))
                         outcomes);
                  Ok outcomes)))
  | World (name, h) ->
      let required = world_required cctx (Eval.store ctx) in
      let missing = List.filter (fun r -> not (List.exists (Hash.equal r) granted)) required in
      if missing <> [] then
        let names =
          List.filter_map
            (fun mh ->
              List.find_map
                (fun (n, { Resolve.hash; kind }) ->
                  if kind = Resolve.KEffect && Hash.equal hash mh then Some n else None)
                (Store.names (Eval.store ctx)))
            missing
        in
        Ok
          [
            {
              display = name;
              verdict = None;
              note = Some (Printf.sprintf "refused: requires --allow %s" (String.concat "," names));
              coverage = [];
              cached = false;
            };
          ]
      else
        Result.bind
          (Result.map_error Runtime_err.to_string (value_of ctx h))
          (fun v ->
            run_value ctx ~test_run ~prop_mode ~schedule_plan:Default_schedule ~member:h
              ~schedule_path:[] ~structural_path:[ 0 ] ~display:name v)

(* --- rendering --- *)

let render_outcome (t : totals) (o : outcome) : string list =
  match (o.verdict, o.note) with
  | Some (Pass n), note ->
      t.passed <- t.passed + 1;
      if o.cached then t.hits <- t.hits + 1 else t.ran <- t.ran + 1;
      let proof =
        match note with
        | Some n -> String.length n >= 8 && String.sub n 0 8 = "verified"
        | None -> false
      in
      let detail =
        match note with
        | Some n -> n
        | None -> Printf.sprintf "%d check%s" n (if n = 1 then "" else "s")
      in
      [
        Printf.sprintf "PASS %s (%s)%s" o.display detail
          (if o.cached then if proof then " [cached proof]" else " [cached]" else "");
      ]
  | Some NoChecks, _ ->
      t.passed <- t.passed + 1;
      if o.cached then t.hits <- t.hits + 1 else t.ran <- t.ran + 1;
      [
        Printf.sprintf "WARN %s: made no checks%s" o.display (if o.cached then " [cached]" else "");
      ]
  | Some (Fail { soft; hard }), note -> (
      t.failed <- t.failed + 1;
      if o.cached then t.hits <- t.hits + 1 else t.ran <- t.ran + 1;
      Printf.sprintf "FAIL %s%s%s" o.display
        (match note with Some n -> " (" ^ n ^ ")" | None -> "")
        (if o.cached then " [cached]" else "")
      :: List.map (fun l -> "  - " ^ l) soft
      @ match hard with Some h -> [ "  ! " ^ h ] | None -> [])
  | None, Some note when String.length note >= 7 && String.sub note 0 7 = "refused" ->
      t.refused <- t.refused + 1;
      [ Printf.sprintf "REFUSED %s: %s" o.display (String.sub note 9 (String.length note - 9)) ]
  | None, note ->
      t.skipped <- t.skipped + 1;
      [ Printf.sprintf "SKIP %s (%s)" o.display (Option.value note ~default:"skipped") ]

(** [parse_rings path] reads a rings manifest when one ships with the prelude, for ring-grouped
    coverage rendering; absent or malformed manifests degrade to no grouping. *)
let parse_rings path : (string * int) list =
  match open_in path with
  | exception Sys_error _ -> []
  | ic ->
      let rec go acc =
        match input_line ic with
        | exception End_of_file ->
            close_in ic;
            List.rev acc
        | line -> (
            let line = String.trim line in
            if line = "" || line.[0] = '#' then go acc
            else
              match String.split_on_char ' ' line with
              | [ name; ring ] -> (
                  match int_of_string_opt ring with
                  | Some r -> go ((name, r) :: acc)
                  | None -> go acc)
              | _ -> go acc)
      in
      go []

(** [coverage_report store ~rings ~tests union] renders the complement: every KTerm name whose
    member hash was never loaded, minus the tests themselves, grouped by ring when the manifest maps
    the name. *)
let coverage_report (store : Store.t) ~(rings : (string * int) list) ~(tests : Hash.t list)
    (union : (Hash.t, unit) Hashtbl.t) : string list =
  let all =
    List.filter_map
      (fun (n, { Resolve.hash; kind }) ->
        if kind = Resolve.KTerm && not (List.exists (Hash.equal hash) tests) then Some (n, hash)
        else None)
      (Store.names store)
  in
  let covered, uncovered =
    List.partition (fun (_, h) -> Hashtbl.mem union h) (List.sort_uniq compare all)
  in
  let ring_of n = List.assoc_opt n rings in
  let annotated =
    List.map (fun (n, _) -> (ring_of n, n)) uncovered
    |> List.sort (fun (ra, na) (rb, nb) -> match compare ra rb with 0 -> compare na nb | c -> c)
  in
  Printf.sprintf "coverage: %d of %d definitions executed" (List.length covered) (List.length all)
  :: List.map
       (fun (r, n) ->
         match r with
         | Some r -> Printf.sprintf "  uncovered %s (ring %d)" n r
         | None -> Printf.sprintf "  uncovered %s" n)
       annotated
