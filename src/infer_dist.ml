(** Discrete probabilistic inference (plan W4.2 enumeration, W4.3 likelihood weighting).

    Both algorithms are HANDLERS over the same untouched model — the M3 thesis. The model is any
    zero-ary function (or expression) whose row includes [dist]; the two entry points install
    different native semantics for [sample]/[observe]:

    - {!enumerate}: exact inference. On [sample d], resume once per support element (the multi-shot
      machinery doing its job), weighting each branch by [pmf d x]; on [observe d v], multiply the
      branch weight by [pmf d v]; collect (value, weight) leaves; normalize. Branches whose weight
      underflows to exactly 0.0 are pruned. An impossible observation set (total mass 0) reports
      E0901 rather than dividing by zero.
    - {!likelihood_weighting}: approximate inference. Run K independent executions; [sample] draws
      ancestrally from the seeded splittable PRNG (single resume); [observe] multiplies the run's
      weight; report the normalized empirical posterior.

    Mechanism: both algorithms drive the machine through {!Eval.run_state_capturing}. When an
    unhandled [sample] or [observe] reaches the root, the algorithm receives the whole remaining
    continuation as immutable data and resumes it per its semantics — enumeration invokes the SAME
    continuation once per support element (multi-shot), likelihood weighting exactly once per run.
    The model file is identical under both algorithms; only the driver changes. *)

open Value

type weighted = { value : Value.t; weight : float }

type posterior = { entries : (Value.t * float) list }
(** normalized, sorted by probability descending then rendering for determinism *)

let err ~code fmt = Printf.ksprintf (fun msg -> Error [ Diag.error ~code msg ]) fmt

(* --- distribution values --- *)

type dist_v = Bernoulli of float | Categorical of (Value.t * float) list

(* Recognize a runtime distribution value built from the prelude constructors. *)
let dist_of_value (ctx : Eval.ctx) (v : Value.t) : (dist_v, Runtime_err.t) result =
  ignore ctx;
  match v with
  | VCon { name = "bernoulli"; args = [ VReal p ]; _ } ->
      if p < 0.0 || p > 1.0 || Float.is_nan p then
        Error (Runtime_err.Arithmetic (Printf.sprintf "bernoulli parameter %g is not in [0, 1]" p))
      else Ok (Bernoulli p)
  | VCon { name = "categorical"; args = [ entries ]; _ } ->
      let rec entries_of = function
        | VCon { name = "nil"; _ } -> Ok []
        | VCon
            {
              name = "cons";
              args = [ VCon { name = "mk-pair"; args = [ x; VReal w ]; _ }; rest ];
              _;
            } ->
            Result.map (fun tail -> (x, w) :: tail) (entries_of rest)
        | v ->
            Error
              (Runtime_err.Type_error
                 (Printf.sprintf "categorical expects a list of pairs, got %s" (Value.show v)))
      in
      Result.map (fun es -> Categorical es) (entries_of entries)
  | v ->
      Error
        (Runtime_err.Type_error (Printf.sprintf "%s is not a distribution value" (Value.show v)))

(* Support with probabilities. Bernoulli's support uses the prelude bool constructors. *)
let support ctx (d : dist_v) : ((Value.t * float) list, Runtime_err.t) result =
  match d with
  | Bernoulli p -> (
      match
        ( Store.lookup_kind ctx.Eval.store "true" Resolve.KCon,
          Store.lookup_kind ctx.Eval.store "false" Resolve.KCon )
      with
      | Some { Resolve.hash = t; _ }, Some { Resolve.hash = f; _ } ->
          Ok
            [
              (VCon { con = t; name = "true"; args = [] }, p);
              (VCon { con = f; name = "false"; args = [] }, 1. -. p);
            ]
      | _ -> Error (Runtime_err.Unresolved "prelude bool constructors"))
  | Categorical entries -> Ok entries

(** [pmf d v]: probability mass of [v] under [d]; 0.0 off-support. *)
let pmf ctx (d : dist_v) (v : Value.t) : (float, Runtime_err.t) result =
  Result.map
    (fun entries ->
      List.fold_left
        (fun acc (x, w) -> if Value.show x = Value.show v then acc +. w else acc)
        0.0 entries)
    (support ctx d)

(* value equality via stable rendering: fine for the discrete literals/constructors the
   support can contain *)

(* --- driving the machine --- *)

(* Run a state to either a terminal value or the first root-reaching dist op. *)
type outcome = Done of Value.t | Op of { name : string; args : Value.t list; resume : Value.t }

let run_until_op (ctx : Eval.ctx) (state : Eval.state) : (outcome, Runtime_err.t) result =
  match Eval.run_state_capturing ctx state with
  | Ok (Eval.CValue v) -> Ok (Done v)
  | Ok (Eval.COp { name; args; kont; _ }) -> Ok (Op { name; args; resume = VResume kont })
  | Error e -> Error e

(* --- enumeration (W4.2) --- *)

let branch_counter = ref 0

(** [enumerate ctx state] runs exact enumeration of a model state (build one with {!Eval.expr_state}
    or {!Eval.apply_state}). *)
let enumerate (ctx : Eval.ctx) (model : Eval.state) : (posterior, Diag.t list) result =
  branch_counter := 0;
  let leaves : weighted list ref = ref [] in
  let rec explore (state : Eval.state) (weight : float) : (unit, Runtime_err.t) result =
    if weight = 0.0 then begin
      (* pruned: still a complete path for the branch counter (the two-coins model must
         count exactly 4, proving no duplicate resumption) *)
      incr branch_counter;
      Ok ()
    end
    else
      match run_until_op ctx state with
      | Error e -> Error e
      | Ok (Done v) ->
          incr branch_counter;
          leaves := { value = v; weight } :: !leaves;
          Ok ()
      | Ok (Op { name = "sample"; args = [ dv ]; resume = VResume kont }) -> (
          match Result.bind (dist_of_value ctx dv) (support ctx) with
          | Error e -> Error e
          | Ok entries ->
              let rec branches = function
                | [] -> Ok ()
                | (x, p) :: rest -> (
                    match explore (Eval.resume_state kont x) (weight *. p) with
                    | Error e -> Error e
                    | Ok () -> branches rest)
              in
              branches entries)
      | Ok (Op { name = "observe"; args = [ dv; v ]; resume = VResume kont }) -> (
          match Result.bind (dist_of_value ctx dv) (fun d -> pmf ctx d v) with
          | Error e -> Error e
          | Ok p -> explore (Eval.resume_state kont Value.unit_v) (weight *. p))
      | Ok (Op { name; args; _ }) ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "enumerate: unexpected op %s/%d" name (List.length args)))
  in
  match explore model 1.0 with
  | Error e -> Error [ Diag.error ~code:"E0902" (Runtime_err.to_string e) ]
  | Ok () ->
      let total = List.fold_left (fun acc { weight; _ } -> acc +. weight) 0.0 !leaves in
      if total <= 0.0 then
        err ~code:"E0901"
          "the posterior is empty: every branch is impossible under the observations"
      else
        (* merge equal values, normalize, sort by probability then rendering *)
        let tbl : (string, Value.t * float ref) Hashtbl.t = Hashtbl.create 16 in
        List.iter
          (fun { value; weight } ->
            let key = Value.show value in
            match Hashtbl.find_opt tbl key with
            | Some (_, w) -> w := !w +. weight
            | None -> Hashtbl.add tbl key (value, ref weight))
          !leaves;
        let entries =
          Hashtbl.fold (fun _ (v, w) acc -> (v, !w /. total) :: acc) tbl []
          |> List.sort (fun (va, pa) (vb, pb) ->
              match compare pb pa with 0 -> compare (Value.show va) (Value.show vb) | c -> c)
        in
        Ok { entries }

(** Branches explored by the last {!enumerate} (instrumentation for the no-duplicate test). *)
let last_branch_count () = !branch_counter

(* --- likelihood weighting (W4.3) --- *)

(* splitmix64 (decision D4): deterministic and seedable; the finalizer and constants follow
   the reference. [split] reseeds a child from the parent's next output with the same fixed
   gamma — a simplification of reference SplitMix's per-split gamma derivation, adequate for
   the discrete M3 demos (the finalizer scrambles child seeds) and deterministic on 64-bit
   platforms (the cram goldens assume 64-bit). *)
module Rng = struct
  type t = { mutable state : int64 }

  let make seed = { state = Int64.of_int seed }

  let next_int64 t =
    t.state <- Int64.add t.state 0x9E3779B97F4A7C15L;
    let z = t.state in
    let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
    let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 27)) 0x94D049BB133111EBL in
    Int64.logxor z (Int64.shift_right_logical z 31)

  (* uniform in [0,1) from the top 53 bits *)
  let float t =
    let bits = Int64.shift_right_logical (next_int64 t) 11 in
    Int64.to_float bits /. 9007199254740992.0

  let split t = make (Int64.to_int (next_int64 t))
end

(* Ancestral draw by inverse CDF over NORMALIZED weights (support may carry an unnormalized
   categorical; without normalization a right-edge u would bias toward the first entry). *)
let draw rng entries =
  let total = List.fold_left (fun acc (_, p) -> acc +. p) 0.0 entries in
  let u = Rng.float rng *. if total > 0.0 then total else 1.0 in
  let rec go acc = function
    | [] -> ( match List.rev entries with (x, _) :: _ -> x | [] -> Value.unit_v)
    | (x, p) :: rest -> if u < acc +. p then x else go (acc +. p) rest
  in
  go 0.0 entries

(** [likelihood_weighting ctx ~seed ~samples model] runs K weighted executions of a model state
    THUNK (a function producing the state, so each run restarts evaluation). *)
let likelihood_weighting (ctx : Eval.ctx) ~seed ~samples (model : unit -> Eval.state) :
    (posterior, Diag.t list) result =
  let master = Rng.make seed in
  let runs : weighted list ref = ref [] in
  let rec one_run rng (state : Eval.state) (weight : float) : (unit, Runtime_err.t) result =
    match run_until_op ctx state with
    | Error e -> Error e
    | Ok (Done v) ->
        runs := { value = v; weight } :: !runs;
        Ok ()
    | Ok (Op { name = "sample"; args = [ dv ]; resume = VResume kont }) -> (
        match Result.bind (dist_of_value ctx dv) (support ctx) with
        | Error e -> Error e
        | Ok entries -> one_run rng (Eval.resume_state kont (draw rng entries)) weight)
    | Ok (Op { name = "observe"; args = [ dv; v ]; resume = VResume kont }) -> (
        match Result.bind (dist_of_value ctx dv) (fun d -> pmf ctx d v) with
        | Error e -> Error e
        | Ok p -> one_run rng (Eval.resume_state kont Value.unit_v) (weight *. p))
    | Ok (Op { name; _ }) -> Error (Runtime_err.Unhandled { effect_ = "dist"; op = name })
  in
  let rec k_runs i =
    if i >= samples then Ok ()
    else
      let rng = Rng.split master in
      match one_run rng (model ()) 1.0 with Error e -> Error e | Ok () -> k_runs (i + 1)
  in
  match k_runs 0 with
  | Error e -> Error [ Diag.error ~code:"E0902" (Runtime_err.to_string e) ]
  | Ok () ->
      let total = List.fold_left (fun acc { weight; _ } -> acc +. weight) 0.0 !runs in
      if total <= 0.0 then
        err ~code:"E0901" "the posterior is empty: every run is impossible under the observations"
      else
        let tbl : (string, Value.t * float ref) Hashtbl.t = Hashtbl.create 16 in
        List.iter
          (fun { value; weight } ->
            let key = Value.show value in
            match Hashtbl.find_opt tbl key with
            | Some (_, w) -> w := !w +. weight
            | None -> Hashtbl.add tbl key (value, ref weight))
          !runs;
        let entries =
          Hashtbl.fold (fun _ (v, w) acc -> (v, !w /. total) :: acc) tbl []
          |> List.sort (fun (va, pa) (vb, pb) ->
              match compare pb pa with 0 -> compare (Value.show va) (Value.show vb) | c -> c)
        in
        Ok { entries }

(** Render a posterior table, one row per value, probabilities to 6 places. *)
let show_posterior (p : posterior) : string =
  String.concat "\n"
    (List.map (fun (v, pr) -> Printf.sprintf "%.6f  %s" pr (Value.show v)) p.entries)
