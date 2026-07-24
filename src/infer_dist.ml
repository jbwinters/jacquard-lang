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

type risk_weights = { low : float; medium : float; high : float; forbidden : float }
(** Raw, unnormalized binary64 weights in the released risk order. Exact risk enumeration
    accumulates duplicate terminal leaves into these four fields without projecting or normalizing
    them. *)

type risk_positive_support = { low : bool; medium : bool; high : bool; forbidden : bool }
(** Theoretical positive reachability in the released risk order. A field is [true] when at least
    one terminal path to that risk has only strictly positive support factors, even if multiplying
    those factors underflows to binary64 zero. *)

type risk_branch_accounting = {
  completed : int;
  positive : int;
  zero_weight : int;
  underflowed : int;
}
(** Terminal-path accounting for one bounded exact risk enumeration. [positive] counts paths with
    theoretical positive support, [zero_weight] counts paths containing an explicit zero support
    factor, and [underflowed] is the subset of [positive] whose binary64 path weight became zero. *)

type exact_risk_enumeration = {
  weights : risk_weights;
  positive_support : risk_positive_support;
  branches : risk_branch_accounting;
}
(** Decision-neutral evidence from bounded exact enumeration. The record contains raw weights,
    theoretical support, and branch accounting only; normalization and policy projection are
    deliberately separate contracts. *)

let diagnostic ~code cause =
  let summary, next_step =
    match code with
    | "E0901" ->
        ( "The posterior is empty.",
          "Change the model or observations so at least one execution branch has nonzero weight." )
    | "E0902" ->
        ( "Probabilistic inference stopped on a runtime failure.",
          "Correct the reported model runtime failure and rerun inference." )
    | "E0910" ->
        ( "The exact risk-enumeration configuration is invalid.",
          "Supply a strictly positive max_branches budget." )
    | "E0911" ->
        ( "The exact risk model contains an invalid finite distribution.",
          "Use only finite discrete supports whose every weight is finite and nonnegative." )
    | "E0912" ->
        ( "Exact risk enumeration exceeded its branch budget.",
          "Raise max_branches only after reviewing the model's finite support size." )
    | "E0913" ->
        ( "The exact risk model returned a non-Risk value.",
          "Return one released Risk constructor: low, medium, high, or forbidden." )
    | "E0914" ->
        ( "The exact risk model performed an unexpected effect.",
          "Keep the exact model closed except for the released Dist sample and observe operations."
        )
    | "E0915" ->
        ( "Exact risk enumeration stopped on a runtime failure.",
          "Correct the reported model runtime failure and rerun exact risk enumeration." )
    | "E0916" ->
        ( "Exact risk enumeration produced a non-finite raw weight.",
          "Rescale the finite model weights so path multiplication and risk accumulation stay \
           finite." )
    | _ -> raise (Diag.Bug_invalid_diagnostic ("unknown inference diagnostic code " ^ code))
  in
  Diag.error ~domain:Inference ~code ~summary ~cause ~next_step ~contrast:None ()

let err ~code fmt = Printf.ksprintf (fun cause -> Error [ diagnostic ~code cause ]) fmt

(* --- distribution values --- *)

type dist_v =
  | Bernoulli of float
  | Categorical of (Value.t * float) list
  | UniformInt of int * int (* lo..hi inclusive (SL.7) *)

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
  | VCon { name = "uniform-int"; args = [ VInt lo; VInt hi ]; _ } ->
      if hi < lo then
        Error (Runtime_err.Arithmetic (Printf.sprintf "uniform-int range %d..%d is empty" lo hi))
      else Ok (UniformInt (lo, hi))
  | v ->
      Error
        (Runtime_err.Type_error (Printf.sprintf "%s is not a distribution value" (Value.show v)))

(* Support with probabilities. Bernoulli's support uses the prelude bool constructors. *)
let support ctx (d : dist_v) : ((Value.t * float) list, Runtime_err.t) result =
  match d with
  | Bernoulli p -> (
      match
        ( Store.lookup_kind (Eval.store ctx) "true" Resolve.KCon,
          Store.lookup_kind (Eval.store ctx) "false" Resolve.KCon )
      with
      | Some { Resolve.hash = t; _ }, Some { Resolve.hash = f; _ } ->
          Ok
            [
              (VCon { con = t; name = "true"; args = [] }, p);
              (VCon { con = f; name = "false"; args = [] }, 1. -. p);
            ]
      | _ -> Error (Runtime_err.Unresolved "prelude bool constructors"))
  | Categorical entries -> Ok entries
  | UniformInt (lo, hi) ->
      (* enumeration support is the whole range; budget-capped so a huge range is a clean
         error instead of an out-of-memory list *)
      let n = hi - lo + 1 in
      if n > 10_000 then
        Error
          (Runtime_err.Arithmetic
             (Printf.sprintf "uniform-int %d..%d has %d outcomes; enumeration caps at 10000" lo hi n))
      else
        let p = 1.0 /. float_of_int n in
        Ok (List.init n (fun i -> (Value.VInt (lo + i), p)))

(** [pmf d v]: probability mass of [v] under [d]; 0.0 off-support. UniformInt is computed directly
    so its pmf works on ranges the enumeration cap refuses. *)
let pmf ctx (d : dist_v) (v : Value.t) : (float, Runtime_err.t) result =
  match d with
  | UniformInt (lo, hi) ->
      let n = float_of_int (hi - lo + 1) in
      Ok (match v with Value.VInt x when x >= lo && x <= hi -> 1.0 /. n | _ -> 0.0)
  | _ ->
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
type outcome =
  | Done of Value.t
  | Op of { op : Hash.t; name : string; args : Value.t list; resume : Eval.captured_kont }

type validated_outcome =
  | Validated_done of Value.t
  | Validated_op of {
      op : Hash.t;
      name : string;
      args : Value.t list;
      resume : Eval.validated_captured_kont;
    }

let run_until_op (ctx : Eval.ctx) (state : Eval.state) : (outcome, Runtime_err.t) result =
  match Eval.run_state_capturing ctx state with
  | Ok (Eval.CValue v) -> Ok (Done v)
  | Ok (Eval.COp { op; name; args; kont }) -> Ok (Op { op; name; args; resume = kont })
  | Error e -> Error e

let run_until_op_validated (ctx : Eval.ctx) (state : Eval.validated_state) :
    (validated_outcome, Runtime_err.t) result =
  match Eval.run_validated_state_capturing ctx state with
  | Ok (Eval.VCValue value) -> Ok (Validated_done value)
  | Ok (Eval.VCOp { op; name; args; kont }) -> Ok (Validated_op { op; name; args; resume = kont })
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
      | Ok (Op { name = "sample"; args = [ dv ]; resume; _ }) -> (
          match Result.bind (dist_of_value ctx dv) (support ctx) with
          | Error e -> Error e
          | Ok entries ->
              let rec branches = function
                | [] -> Ok ()
                | (x, p) :: rest -> (
                    match Eval.resume_captured_state ctx resume x with
                    | Error e -> Error e
                    | Ok state -> (
                        match explore state (weight *. p) with
                        | Error e -> Error e
                        | Ok () -> branches rest))
              in
              branches entries)
      | Ok (Op { name = "observe"; args = [ dv; v ]; resume; _ }) -> (
          match Result.bind (dist_of_value ctx dv) (fun d -> pmf ctx d v) with
          | Error e -> Error e
          | Ok p ->
              Result.bind (Eval.resume_captured_state ctx resume Value.unit_v) (fun state ->
                  explore state (weight *. p)))
      | Ok (Op { name; args; _ }) ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "enumerate: unexpected op %s/%d" name (List.length args)))
  in
  match explore model 1.0 with
  | Error error -> Error [ diagnostic ~code:"E0902" (Runtime_err.to_string error) ]
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

(* --- bounded exact risk enumeration (GM.21 core) --- *)

(** [enumerate_risk_exact ctx ~max_branches model] depth-first enumerates one finite discrete Dist
    model and returns raw weights for the four released Risk constructors. Every categorical support
    weight is validated before its continuation is resumed. [max_branches] is a strictly positive
    terminal-path budget; attempting the next terminal path fails with E0912 rather than returning
    partial evidence.

    The driver accepts only the released [sample] and [observe] operation identities and only
    terminal [low], [medium], [high], or [forbidden] constructor identities. It continues paths
    after binary64 weight underflow and records their theoretical positive support separately.
    Runtime failures, malformed distributions, non-finite arithmetic, unexpected effects, and wrong
    terminal values are diagnostics. This function does not normalize or project the raw result and
    does not alter {!enumerate}. *)
let enumerate_risk_exact (ctx : Eval.ctx) ~max_branches (model : Eval.state) :
    (exact_risk_enumeration, Diag.t list) result =
  if max_branches <= 0 then err ~code:"E0910" "max_branches must be positive, got %d" max_branches
  else
    let ( let* ) = Result.bind in
    let lookup kind name =
      match Store.lookup_kind (Eval.store ctx) name kind with
      | Some { Resolve.hash; _ } -> Ok hash
      | None ->
          err ~code:"E0915" "the released `%s` identity is unavailable in the evaluator store" name
    in
    let* sample_op = lookup Resolve.KOp "sample" in
    let* observe_op = lookup Resolve.KOp "observe" in
    let* low_con = lookup Resolve.KCon "low" in
    let* medium_con = lookup Resolve.KCon "medium" in
    let* high_con = lookup Resolve.KCon "high" in
    let* forbidden_con = lookup Resolve.KCon "forbidden" in
    let finite_nonnegative value =
      match classify_float value with
      | FP_normal | FP_subnormal | FP_zero -> value >= 0.0
      | FP_infinite | FP_nan -> false
    in
    let finite value =
      match classify_float value with
      | FP_normal | FP_subnormal | FP_zero -> true
      | FP_infinite | FP_nan -> false
    in
    let canonical_zero value = if value = 0.0 then 0.0 else value in
    let invalid_distribution fmt =
      Printf.ksprintf (fun cause -> Error [ diagnostic ~code:"E0911" cause ]) fmt
    in
    let invalid_arithmetic fmt =
      Printf.ksprintf (fun cause -> Error [ diagnostic ~code:"E0916" cause ]) fmt
    in
    let runtime_failure fmt =
      Printf.ksprintf (fun cause -> Error [ diagnostic ~code:"E0915" cause ]) fmt
    in
    let decode_distribution value =
      match dist_of_value ctx value with
      | Ok distribution -> Ok distribution
      | Error error -> invalid_distribution "%s" (Runtime_err.to_string error)
    in
    let validate_entries operation entries =
      let rec validate index = function
        | [] -> Ok entries
        | (_, weight) :: rest ->
            if finite_nonnegative weight then validate (index + 1) rest
            else
              invalid_distribution
                "%s support weight %d is %g; every support weight must be finite and nonnegative"
                operation index weight
      in
      validate 0 entries
    in
    let materialized_support operation distribution =
      match support ctx distribution with
      | Error error -> runtime_failure "%s" (Runtime_err.to_string error)
      | Ok entries -> validate_entries operation entries
    in
    let uniform_probability lo hi =
      let count = float_of_int hi -. float_of_int lo +. 1.0 in
      let probability = 1.0 /. count in
      if finite_nonnegative probability && probability > 0.0 then Ok probability
      else
        invalid_arithmetic "uniform-int %d..%d produced invalid support weight %g" lo hi probability
    in
    let rec comparable_value = function
      | Value.VInt _ | VReal _ | VText _ | VHash _ -> Ok ()
      | VTuple items -> comparable_values items
      | VCon { args; _ } -> comparable_values args
      | value ->
          invalid_distribution
            "exact observe requires transparent data support; opaque or executable value %s is not \
             comparable"
            (Value.show value)
    and comparable_values = function
      | [] -> Ok ()
      | value :: rest ->
          let* () = comparable_value value in
          comparable_values rest
    in
    let rec same_comparable_value left right =
      let* () = comparable_value left in
      let* () = comparable_value right in
      match (left, right) with
      | Value.VInt a, VInt b -> Ok (Int.equal a b)
      | VReal a, VReal b -> Ok (Float.equal a b)
      | VText a, VText b -> Ok (String.equal a b)
      | VHash a, VHash b -> Ok (Hash.equal a b)
      | VTuple left_items, VTuple right_items -> same_comparable_values left_items right_items
      | VCon left_con, VCon right_con ->
          if Hash.equal left_con.con right_con.con then
            same_comparable_values left_con.args right_con.args
          else Ok false
      | _ -> Ok false
    and same_comparable_values left right =
      match (left, right) with
      | [], [] -> Ok true
      | left_value :: left_rest, right_value :: right_rest ->
          let* same = same_comparable_value left_value right_value in
          if same then same_comparable_values left_rest right_rest else Ok false
      | _ -> Ok false
    in
    let observation_mass distribution observed =
      match distribution with
      | UniformInt (lo, hi) ->
          let* probability = uniform_probability lo hi in
          Ok
            (match observed with
            | Value.VInt value when value >= lo && value <= hi -> (probability, true)
            | _ -> (0.0, false))
      | Bernoulli _ | Categorical _ ->
          let* entries = materialized_support "observe" distribution in
          let rec sum mass theoretically_positive = function
            | [] -> Ok (canonical_zero mass, theoretically_positive)
            | (value, weight) :: rest ->
                let* same = same_comparable_value value observed in
                if same then
                  let next = mass +. weight in
                  if finite next then sum next (theoretically_positive || weight > 0.0) rest
                  else
                    invalid_arithmetic
                      "observe support accumulation overflowed for value %s in support order"
                      (Value.show observed)
                else sum mass theoretically_positive rest
          in
          sum 0.0 false entries
    in
    let multiply path_weight factor =
      let product = path_weight *. factor in
      if finite product then Ok (canonical_zero product)
      else
        invalid_arithmetic "path-weight multiplication produced %g from %g * %g" product path_weight
          factor
    in
    let weights = ref ({ low = 0.0; medium = 0.0; high = 0.0; forbidden = 0.0 } : risk_weights) in
    let positive_support =
      ref ({ low = false; medium = false; high = false; forbidden = false } : risk_positive_support)
    in
    let completed = ref 0 in
    let positive = ref 0 in
    let zero_weight = ref 0 in
    let underflowed = ref 0 in
    let classify_risk = function
      | VCon { con; args = []; _ } when Hash.equal con low_con -> Ok 0
      | VCon { con; args = []; _ } when Hash.equal con medium_con -> Ok 1
      | VCon { con; args = []; _ } when Hash.equal con high_con -> Ok 2
      | VCon { con; args = []; _ } when Hash.equal con forbidden_con -> Ok 3
      | value -> err ~code:"E0913" "expected a released Risk constructor, got %s" (Value.show value)
    in
    let add_terminal risk path_weight theoretically_positive =
      let current = !weights in
      let add prior =
        let total = prior +. path_weight in
        if finite total then Ok (canonical_zero total)
        else
          invalid_arithmetic
            "raw risk-weight accumulation overflowed while adding terminal weight %g" path_weight
      in
      let* total =
        match risk with
        | 0 -> add current.low
        | 1 -> add current.medium
        | 2 -> add current.high
        | 3 -> add current.forbidden
        | _ -> assert false
      in
      (weights :=
         match risk with
         | 0 -> { current with low = total }
         | 1 -> { current with medium = total }
         | 2 -> { current with high = total }
         | 3 -> { current with forbidden = total }
         | _ -> assert false);
      if theoretically_positive then begin
        let support = !positive_support in
        positive_support :=
          match risk with
          | 0 -> { support with low = true }
          | 1 -> { support with medium = true }
          | 2 -> { support with high = true }
          | 3 -> { support with forbidden = true }
          | _ -> assert false
      end;
      Ok ()
    in
    let resume continuation value =
      match Eval.resume_captured_state ctx continuation value with
      | Ok state -> Ok state
      | Error error -> runtime_failure "%s" (Runtime_err.to_string error)
    in
    let rec explore state path_weight theoretically_positive =
      match run_until_op ctx state with
      | Error error -> runtime_failure "%s" (Runtime_err.to_string error)
      | Ok (Done value) ->
          if !completed >= max_branches then
            err ~code:"E0912"
              "max_branches=%d was exhausted after %d terminal paths; no partial result was \
               returned"
              max_branches !completed
          else
            let* risk = classify_risk value in
            incr completed;
            if theoretically_positive then begin
              incr positive;
              if path_weight = 0.0 then incr underflowed
            end
            else incr zero_weight;
            add_terminal risk path_weight theoretically_positive
      | Ok (Op { op; args; resume = continuation; _ }) when Hash.equal op sample_op -> (
          match args with
          | [ distribution_value ] -> (
              let* distribution = decode_distribution distribution_value in
              let visit value factor =
                let* path_weight = multiply path_weight factor in
                let* state = resume continuation value in
                explore state path_weight (theoretically_positive && factor > 0.0)
              in
              match distribution with
              | UniformInt (lo, hi) ->
                  let* probability = uniform_probability lo hi in
                  let rec visit_range value =
                    let* () = visit (Value.VInt value) probability in
                    if value = hi then Ok () else visit_range (value + 1)
                  in
                  visit_range lo
              | Bernoulli _ | Categorical _ ->
                  let* entries = materialized_support "sample" distribution in
                  let rec visit_entries = function
                    | [] -> Ok ()
                    | (value, factor) :: rest ->
                        let* () = visit value factor in
                        visit_entries rest
                  in
                  visit_entries entries)
          | _ ->
              invalid_distribution "sample expects one distribution, got %d arguments"
                (List.length args))
      | Ok (Op { op; args; resume = continuation; _ }) when Hash.equal op observe_op -> (
          match args with
          | [ distribution_value; observed ] ->
              let* distribution = decode_distribution distribution_value in
              let* factor, factor_positive = observation_mass distribution observed in
              let* path_weight = multiply path_weight factor in
              let* state = resume continuation Value.unit_v in
              explore state path_weight (theoretically_positive && factor_positive)
          | _ ->
              invalid_distribution "observe expects a distribution and a value, got %d arguments"
                (List.length args))
      | Ok (Op { op; name; args; _ }) ->
          err ~code:"E0914" "unexpected operation %s/%d (%s)" name (List.length args)
            (Hash.to_hex op)
    in
    let* () = explore model 1.0 true in
    Ok
      {
        weights = !weights;
        positive_support = !positive_support;
        branches =
          {
            completed = !completed;
            positive = !positive;
            zero_weight = !zero_weight;
            underflowed = !underflowed;
          };
      }

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

  (** [bounded_int t bound] draws uniformly from zero (inclusive) to [bound] (exclusive). It uses 62
      unsigned bits and rejection sampling, so non-power-of-two bounds have no modulo/float bias and
      every positive OCaml-int bound is range-safe on the supported 64-bit runtime. *)
  let bounded_int t bound =
    if bound <= 0 then invalid_arg "Infer_dist.Rng.bounded_int: bound must be positive";
    let range = Int64.shift_left 1L 62 in
    let bound = Int64.of_int bound in
    let limit = Int64.sub range (Int64.rem range bound) in
    let rec draw () =
      let bits = Int64.shift_right_logical (next_int64 t) 2 in
      if Int64.compare bits limit < 0 then Int64.to_int (Int64.rem bits bound) else draw ()
    in
    draw ()

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

(** [sample_dist ctx rng d] draws one value from [d] — directly for UniformInt (huge ranges must not
    materialize a support list), by inverse CDF over the support otherwise. *)
let sample_dist ctx rng (d : dist_v) : (Value.t, Runtime_err.t) result =
  match d with
  | UniformInt (lo, hi) ->
      let n = hi - lo + 1 in
      Ok (Value.VInt (lo + int_of_float (Rng.float rng *. float_of_int n)))
  | _ -> Result.map (draw rng) (support ctx d)

(** [likelihood_weighting ctx ~seed ~samples model] obtains one immutable initial state from
    [model], validates it, then reuses it for K independent weighted executions. The factory is
    evaluated exactly once; recovery-marked initial states fail before the first execution. *)
let likelihood_weighting (ctx : Eval.ctx) ~seed ~samples (model : unit -> Eval.state) :
    (posterior, Diag.t list) result =
  let master = Rng.make seed in
  let runs : weighted list ref = ref [] in
  let rec one_run rng (state : Eval.validated_state) (weight : float) : (unit, Runtime_err.t) result
      =
    match run_until_op_validated ctx state with
    | Error e -> Error e
    | Ok (Validated_done v) ->
        runs := { value = v; weight } :: !runs;
        Ok ()
    | Ok (Validated_op { name = "sample"; args = [ dv ]; resume; _ }) -> (
        match Result.bind (dist_of_value ctx dv) (sample_dist ctx rng) with
        | Error e -> Error e
        | Ok x ->
            Result.bind (Eval.resume_validated_state ctx resume x) (fun state ->
                one_run rng state weight))
    | Ok (Validated_op { name = "observe"; args = [ dv; v ]; resume; _ }) -> (
        match Result.bind (dist_of_value ctx dv) (fun d -> pmf ctx d v) with
        | Error e -> Error e
        | Ok p ->
            Result.bind (Eval.resume_validated_state ctx resume Value.unit_v) (fun state ->
                one_run rng state (weight *. p)))
    | Ok (Validated_op { name; _ }) ->
        (* a non-dist op reached the root during a weighted run (unreachable via the CLI,
           which manifest-checks first; the raw harness can get here) *)
        Error (Runtime_err.Unhandled { effect_ = "(not handled during inference)"; op = name })
  in
  let initial = model () in
  let rec k_runs initial i =
    if i >= samples then Ok ()
    else
      let rng = Rng.split master in
      let state = Eval.fresh_validated_state ctx initial in
      match one_run rng state 1.0 with Error e -> Error e | Ok () -> k_runs initial (i + 1)
  in
  match Eval.validate_state_once ctx initial with
  | Error error -> Error [ diagnostic ~code:"E0902" (Runtime_err.to_string error) ]
  | Ok initial -> (
      match k_runs initial 0 with
      | Error error -> Error [ diagnostic ~code:"E0902" (Runtime_err.to_string error) ]
      | Ok () ->
          let total = List.fold_left (fun acc { weight; _ } -> acc +. weight) 0.0 !runs in
          if total <= 0.0 then
            err ~code:"E0901"
              "the posterior is empty: every run is impossible under the observations"
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
            Ok { entries })

(** Render a posterior table, one row per value, probabilities to 6 places. *)
let show_posterior (p : posterior) : string =
  String.concat "\n"
    (List.map (fun (v, pr) -> Printf.sprintf "%.6f  %s" pr (Value.show v)) p.entries)
