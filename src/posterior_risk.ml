(** See {!Posterior_risk}. *)

open Value

let form head children = Form.form head (List.map (fun child -> Form.F child) children)
let lit_text value = Form.form "lit" [ Form.Text value ]
let lit_int value = Form.form "lit" [ Form.Int value ]
let lit_real value = Form.form "lit" [ Form.Real (if value = 0.0 then 0.0 else value) ]
let hash_code value = Form.form "hash" [ Form.Hash value ]
let code_hash value = Hash.of_string (Printer.print_compact value)

let exact_semantics_code =
  form "posterior-risk-exact-semantics-v1"
    [
      lit_text "finite-discrete";
      lit_text "depth-first-support-order";
      lit_text "duplicate-support-entries-preserved";
      lit_text "observe-mass-summed-in-support-order";
      lit_text "observe-transparent-data-structural-equality";
      lit_text "opaque-observe-values-refused";
      lit_text "binary64-path-weight-multiplication";
      lit_text "risk-order-binary64-accumulation";
      lit_text "positive-support-preserved";
      lit_text "terminal-branch-budget-before-next-leaf";
      lit_text "gm20-normalization-v1";
    ]

let approximate_semantics_code =
  form "non-authorizing-posterior-risk-likelihood-weighting-v1"
    [ lit_text "splitmix64"; lit_text "seed-and-sample-count-bound"; lit_text "evidence-only" ]

let diagnostic_text diagnostics =
  diagnostics
  |> List.map (fun diagnostic ->
      Printf.sprintf "%s: %s" (Diag.code_or_uncoded diagnostic) (Diag.to_cause_string diagnostic))
  |> String.concat "; "

let type_error name args =
  Error
    (Runtime_err.Type_error
       (Printf.sprintf "%s received incompatible values: %s" name
          (String.concat ", " (List.map Value.show args))))

let lookup store kind name =
  match Store.lookup_kind store name kind with
  | Some entry -> Ok entry.Resolve.hash
  | None -> Error (Runtime_err.Unresolved ("posterior-risk prelude name " ^ name))

let lookup_internal store kind name =
  match Store.lookup_internal_kind store name kind with
  | Some entry -> Ok entry.Resolve.hash
  | None -> Error (Runtime_err.Unresolved ("posterior-risk prelude name " ^ name))

let constructor store name args =
  Result.map (fun con -> VCon { con; name; args }) (lookup store Resolve.KCon name)

let internal_constructor store name args =
  Result.map (fun con -> VCon { con; name; args }) (lookup_internal store Resolve.KCon name)

let is_constructor store name con =
  match lookup store Resolve.KCon name with
  | Ok expected -> Hash.equal con expected
  | Error _ -> false

let is_internal_constructor store name con =
  match lookup_internal store Resolve.KCon name with
  | Ok expected -> Hash.equal con expected
  | Error _ -> false

let result_constructors store =
  Result.bind (lookup store Resolve.KCon "ok") (fun ok_con ->
      Result.map (fun err_con -> (ok_con, err_con)) (lookup store Resolve.KCon "err"))

let language_result store = function
  | Ok value ->
      Result.map
        (fun (ok_con, _) -> VCon { con = ok_con; name = "ok"; args = [ value ] })
        (result_constructors store)
  | Error message ->
      Result.map
        (fun (_, err_con) -> VCon { con = err_con; name = "err"; args = [ VText message ] })
        (result_constructors store)

let call_term ctx name args =
  let store = Eval.store ctx in
  Result.bind (lookup store Resolve.KTerm name) (fun hash ->
      let expression = Kernel.{ it = Ref (hash, Term); meta = Meta.empty } in
      Result.bind (Eval.run_expr ctx expression) (fun fn -> Eval.call ctx fn args))

let unwrap_result = function
  | VCon { name = "ok"; args = [ value ]; _ } -> Ok value
  | VCon { name = "err"; args = [ VText message ]; _ } -> Error message
  | value -> Error ("trusted validator returned malformed Result: " ^ Value.show value)

let validate_call ctx call =
  match call_term ctx "governance.validate-call" [ call ] with
  | Ok value -> unwrap_result value
  | Error error -> Error (Runtime_err.to_string error)

let validate_assessment ctx assessment =
  match call_term ctx "governance.validate-assessment" [ assessment ] with
  | Ok value -> unwrap_result value
  | Error error -> Error (Runtime_err.to_string error)

let assessment_id ctx assessment =
  match call_term ctx "governance.assessment-id" [ assessment ] with
  | Ok (VHash hash) -> Ok hash
  | Ok value -> Error ("assessment ID boundary returned " ^ Value.show value)
  | Error error -> Error (Runtime_err.to_string error)

let assessment_code ctx assessment =
  match call_term ctx "governance.assessment-code" [ assessment ] with
  | Ok (VCode code) -> Ok code
  | Ok value -> Error ("assessment Code boundary returned " ^ Value.show value)
  | Error error -> Error (Runtime_err.to_string error)

let exact_config_code max_branches = form "posterior-exact-config-v1" [ lit_int max_branches ]

let approximate_config_code samples seed =
  form "posterior-approximate-config-v1" [ lit_int samples; lit_int seed ]

let weights_code (weights : Infer_dist.risk_weights) =
  form "posterior-risk-weights-v1"
    [
      lit_real weights.low;
      lit_real weights.medium;
      lit_real weights.high;
      lit_real weights.forbidden;
    ]

type belief = { low : float; medium : float; high : float; forbidden : float }

let belief_code belief =
  form "posterior-risk-belief-v1"
    [ lit_real belief.low; lit_real belief.medium; lit_real belief.high; lit_real belief.forbidden ]

let bool_code value = form (if value then "true" else "false") []

let positive_support_code (support : Infer_dist.risk_positive_support) =
  form "posterior-risk-positive-support-v1"
    [
      bool_code support.low;
      bool_code support.medium;
      bool_code support.high;
      bool_code support.forbidden;
    ]

let branch_accounting_code (branches : Infer_dist.risk_branch_accounting) =
  form "posterior-risk-branch-accounting-v1"
    [
      lit_int branches.completed;
      lit_int branches.positive;
      lit_int branches.zero_weight;
      lit_int branches.underflowed;
    ]

let finite_nonnegative value = Float.is_finite value && value >= 0.0
let finite_unit value = Float.is_finite value && value >= 0.0 && value <= 1.0
let positive value = value > 0.0
let canonical_zero value = if value = 0.0 then 0.0 else value

let normalize (exact : Infer_dist.exact_risk_enumeration) =
  let raw = exact.weights in
  let support = exact.positive_support in
  let values = [ raw.low; raw.medium; raw.high; raw.forbidden ] in
  if not (List.for_all finite_nonnegative values) then
    Error "E1545: exact posterior weights must be finite and nonnegative"
  else if not (List.exists positive values) then
    Error "E1545: exact posterior is impossible because every raw class weight is zero"
  else if
    (support.low && raw.low = 0.0)
    || (support.medium && raw.medium = 0.0)
    || (support.high && raw.high = 0.0)
    || (support.forbidden && raw.forbidden = 0.0)
  then Error "E1545: exact posterior accumulation lost theoretically positive support"
  else
    let maximum =
      let first = if raw.low > raw.medium then raw.low else raw.medium in
      let second = if first > raw.high then first else raw.high in
      if second > raw.forbidden then second else raw.forbidden
    in
    let q_low = raw.low /. maximum in
    let q_medium = raw.medium /. maximum in
    let q_high = raw.high /. maximum in
    let q_forbidden = raw.forbidden /. maximum in
    let total = q_low +. q_medium +. q_high +. q_forbidden in
    let belief =
      {
        low = canonical_zero (q_low /. total);
        medium = canonical_zero (q_medium /. total);
        high = canonical_zero (q_high /. total);
        forbidden = canonical_zero (q_forbidden /. total);
      }
    in
    if not (List.for_all finite_unit [ belief.low; belief.medium; belief.high; belief.forbidden ])
    then Error "E1545: exact posterior normalization produced an invalid binary64 probability"
    else if
      (positive raw.low && belief.low = 0.0)
      || (positive raw.medium && belief.medium = 0.0)
      || (positive raw.high && belief.high = 0.0)
      || (positive raw.forbidden && belief.forbidden = 0.0)
    then Error "E1545: exact posterior normalization lost positive support"
    else Ok belief

let same_real left right = Int64.equal (Canon.real_bits left) (Canon.real_bits right)

let same_belief left right =
  same_real left.low right.low
  && same_real left.medium right.medium
  && same_real left.high right.high
  && same_real left.forbidden right.forbidden

let check_model_signature store builtin_signatures model_id =
  match Store.locate store model_id with
  | Error diagnostics -> Error ("E1543: model resolution failed: " ^ diagnostic_text diagnostics)
  | Ok { Store.role = Store.Member _; _ } -> (
      match
        ( lookup store Resolve.KType "governance-call",
          lookup store Resolve.KType "risk",
          lookup store Resolve.KEffect "dist" )
      with
      | Ok call_type, Ok risk_type, Ok dist_effect -> (
          match Check.make_ctx store with
          | Error diagnostics ->
              Error ("E1543: model checker initialization failed: " ^ diagnostic_text diagnostics)
          | Ok checker -> (
              Check.register_builtin_signatures checker builtin_signatures;
              match Check.force_term checker model_id with
              | Error diagnostics ->
                  Error ("E1543: model typechecking failed: " ^ diagnostic_text diagnostics)
              | Ok scheme -> (
                  match Types.repr scheme.Types.ty with
                  | Types.TArrow
                      ([ Types.TCon (actual_call, []) ], row, Types.TCon (actual_risk, [])) ->
                      let row = Types.repr_row row in
                      if
                        Hash.equal actual_call call_type && Hash.equal actual_risk risk_type
                        && row.Types.tail = Types.RClosed
                        && List.length row.Types.effects = 1
                        && Hash.equal (List.hd row.Types.effects) dist_effect
                      then Ok ()
                      else
                        Error
                          "E1543: model must have the closed signature (GovernanceCall) ->{Dist} \
                           Risk"
                  | _ ->
                      Error
                        "E1543: model must have the closed signature (GovernanceCall) ->{Dist} Risk"
                  )))
      | _ -> Error "E1543: the complete Governance/Dist prelude is unavailable")
  | Ok _ -> Error "E1543: model hash does not select a term"

let model_function ctx model_id =
  let expression = Kernel.{ it = Ref (model_id, Term); meta = Meta.empty } in
  match Eval.run_expr ctx expression with
  | Ok value -> Ok value
  | Error error -> Error ("E1543: model loading failed: " ^ Runtime_err.to_string error)

let risk_value store name =
  Result.bind (lookup store Resolve.KCon name) (fun con -> Ok (VCon { con; name; args = [] }))

let weights_value store (weights : Infer_dist.risk_weights) =
  constructor store "posterior-risk-weights-v1"
    [ VReal weights.low; VReal weights.medium; VReal weights.high; VReal weights.forbidden ]

let belief_value store belief =
  constructor store "posterior-risk-belief-v1"
    [ VReal belief.low; VReal belief.medium; VReal belief.high; VReal belief.forbidden ]

let bool_value store value =
  let name = if value then "true" else "false" in
  Result.map (fun con -> VCon { con; name; args = [] }) (lookup store Resolve.KCon name)

let positive_support_value store (support : Infer_dist.risk_positive_support) =
  let ( let* ) = Result.bind in
  let* low = bool_value store support.low in
  let* medium = bool_value store support.medium in
  let* high = bool_value store support.high in
  let* forbidden = bool_value store support.forbidden in
  constructor store "posterior-risk-positive-support-v1" [ low; medium; high; forbidden ]

let branch_accounting_value store (branches : Infer_dist.risk_branch_accounting) =
  constructor store "posterior-risk-branch-accounting-v1"
    [
      VInt branches.completed;
      VInt branches.positive;
      VInt branches.zero_weight;
      VInt branches.underflowed;
    ]

let exact_result_subject ~call_id ~model_id ~semantics_id ~config_hash ~evidence_hash ~weights
    ~belief =
  form "posterior-risk-result-v1"
    [
      hash_code call_id;
      hash_code model_id;
      hash_code semantics_id;
      hash_code config_hash;
      hash_code evidence_hash;
      weights_code weights;
      belief_code belief;
    ]

let parse_model_ref store = function
  | VCon { con; name = "posterior-risk-model-ref-v1"; args = [ VHash model_id ] }
    when is_constructor store "posterior-risk-model-ref-v1" con ->
      Ok model_id
  | _ -> Error "E1543: expected PosteriorRiskModelRefV1"

let parse_exact_config store = function
  | VCon { con; name = "posterior-exact-config-v1"; args = [ VInt max_branches ] }
    when is_constructor store "posterior-exact-config-v1" con && max_branches > 0 ->
      Ok max_branches
  | _ -> Error "E1544: exact max-branches must be a positive integer"

let parse_approximate_config store = function
  | VCon { con; name = "posterior-approximate-config-v1"; args = [ VInt samples; VInt seed ] }
    when is_constructor store "posterior-approximate-config-v1" con && samples > 0 ->
      Ok (samples, seed)
  | _ -> Error "E1547: approximate samples must be a positive integer"

let run_exact ctx ~builtin_signatures model_ref config source_evidence call =
  let store = Eval.store ctx in
  let ( let* ) = Result.bind in
  let* model_id = parse_model_ref store model_ref in
  let* max_branches = parse_exact_config store config in
  let* evidence =
    match source_evidence with
    | VCode evidence -> Ok evidence
    | _ -> Error "E1545: exact source evidence must be Code"
  in
  let* call_id =
    match validate_call ctx call with
    | Ok (VHash call_id) -> Ok call_id
    | Ok value -> Error ("E1545: validated Call returned a non-hash identity: " ^ Value.show value)
    | Error message -> Error message
  in
  let* () = check_model_signature store builtin_signatures model_id in
  let* model = model_function ctx model_id in
  let state = Eval.apply_state ctx model [ call ] in
  let* exact =
    match Infer_dist.enumerate_risk_exact ctx ~max_branches state with
    | Ok exact -> Ok exact
    | Error diagnostics ->
        Error ("E1544: exact risk inference failed: " ^ diagnostic_text diagnostics)
  in
  let* normalized = normalize exact in
  let semantics_id = code_hash exact_semantics_code in
  let config_hash = code_hash (exact_config_code max_branches) in
  let evidence_hash = code_hash evidence in
  let subject =
    exact_result_subject ~call_id ~model_id ~semantics_id ~config_hash ~evidence_hash
      ~weights:exact.weights ~belief:normalized
  in
  let posterior_id = code_hash subject in
  let* weights = weights_value store exact.weights |> Result.map_error Runtime_err.to_string in
  let* belief = belief_value store normalized |> Result.map_error Runtime_err.to_string in
  let* positive_support =
    positive_support_value store exact.positive_support |> Result.map_error Runtime_err.to_string
  in
  let* branches =
    branch_accounting_value store exact.branches |> Result.map_error Runtime_err.to_string
  in
  internal_constructor store "posterior-exact-result-v1"
    [
      VHash posterior_id;
      VHash call_id;
      VHash model_id;
      VHash semantics_id;
      config;
      VHash config_hash;
      source_evidence;
      VHash evidence_hash;
      weights;
      belief;
      positive_support;
      branches;
    ]
  |> Result.map_error Runtime_err.to_string

let run_exact_builtin ctx ~builtin_signatures args =
  let store = Eval.store ctx in
  match args with
  | [ model_ref; config; source_evidence; call ] ->
      language_result store
        (run_exact ctx ~builtin_signatures model_ref config source_evidence call)
  | _ -> type_error "posterior.run-exact-v1" args

type parsed_exact = {
  posterior_id : Hash.t;
  call_id : Hash.t;
  model_id : Hash.t;
  semantics_id : Hash.t;
  max_branches : int;
  config_hash : Hash.t;
  source_evidence : Form.t;
  evidence_hash : Hash.t;
  weights : Infer_dist.risk_weights;
  belief : belief;
  positive_support : Infer_dist.risk_positive_support;
  branches : Infer_dist.risk_branch_accounting;
}

let parse_weights store = function
  | VCon
      {
        con;
        name = "posterior-risk-weights-v1";
        args = [ VReal low; VReal medium; VReal high; VReal forbidden ];
      } ->
      if is_constructor store "posterior-risk-weights-v1" con then
        Ok (Infer_dist.{ low; medium; high; forbidden } : Infer_dist.risk_weights)
      else Error "E1545: forged PosteriorRiskWeightsV1 constructor identity"
  | _ -> Error "E1545: malformed PosteriorRiskWeightsV1"

let parse_belief store = function
  | VCon
      {
        con;
        name = "posterior-risk-belief-v1";
        args = [ VReal low; VReal medium; VReal high; VReal forbidden ];
      } ->
      if is_constructor store "posterior-risk-belief-v1" con then
        Ok { low; medium; high; forbidden }
      else Error "E1545: forged PosteriorRiskBeliefV1 constructor identity"
  | _ -> Error "E1545: malformed PosteriorRiskBeliefV1"

let parse_bool store = function
  | VCon { con; name = "true"; args = [] } when is_constructor store "true" con -> Ok true
  | VCon { con; name = "false"; args = [] } when is_constructor store "false" con -> Ok false
  | _ -> Error "E1545: malformed Bool in exact posterior support"

let parse_positive_support store = function
  | VCon
      { con; name = "posterior-risk-positive-support-v1"; args = [ low; medium; high; forbidden ] }
    when is_constructor store "posterior-risk-positive-support-v1" con ->
      let ( let* ) = Result.bind in
      let* low = parse_bool store low in
      let* medium = parse_bool store medium in
      let* high = parse_bool store high in
      let* forbidden = parse_bool store forbidden in
      Ok (Infer_dist.{ low; medium; high; forbidden } : Infer_dist.risk_positive_support)
  | _ -> Error "E1545: malformed PosteriorRiskPositiveSupportV1"

let parse_branch_accounting store = function
  | VCon
      {
        con;
        name = "posterior-risk-branch-accounting-v1";
        args = [ VInt completed; VInt positive; VInt zero_weight; VInt underflowed ];
      }
    when is_constructor store "posterior-risk-branch-accounting-v1" con
         && completed >= 0 && positive >= 0 && zero_weight >= 0 && underflowed >= 0
         && completed = positive + zero_weight
         && underflowed <= positive ->
      Ok
        (Infer_dist.{ completed; positive; zero_weight; underflowed }
          : Infer_dist.risk_branch_accounting)
  | _ -> Error "E1545: malformed PosteriorRiskBranchAccountingV1"

let parse_exact_result store = function
  | VCon
      {
        con;
        name = "posterior-exact-result-v1";
        args =
          [
            VHash posterior_id;
            VHash call_id;
            VHash model_id;
            VHash semantics_id;
            config;
            VHash config_hash;
            VCode source_evidence;
            VHash evidence_hash;
            weights;
            belief;
            positive_support;
            branches;
          ];
      } ->
      if not (is_internal_constructor store "posterior-exact-result-v1" con) then
        Error "E1545: forged ExactPosteriorRiskResultV1 constructor identity"
      else
        Result.bind (parse_exact_config store config) (fun max_branches ->
            Result.bind (parse_weights store weights) (fun weights ->
                Result.bind (parse_belief store belief) (fun belief ->
                    Result.bind (parse_positive_support store positive_support)
                      (fun positive_support ->
                        Result.map
                          (fun branches ->
                            {
                              posterior_id;
                              call_id;
                              model_id;
                              semantics_id;
                              max_branches;
                              config_hash;
                              source_evidence;
                              evidence_hash;
                              weights;
                              belief;
                              positive_support;
                              branches;
                            })
                          (parse_branch_accounting store branches)))))
  | _ -> Error "E1545: malformed ExactPosteriorRiskResultV1"

let risk_rank = function
  | "low" -> Some 0
  | "medium" -> Some 1
  | "high" -> Some 2
  | "forbidden" -> Some 3
  | _ -> None

let risk_name = function 0 -> "low" | 1 -> "medium" | 2 -> "high" | _ -> "forbidden"

let rule_code store = function
  | VCon { con; name = "posterior-worst-case-v1"; args = [] }
    when is_constructor store "posterior-worst-case-v1" con ->
      Ok (form "posterior-worst-case-v1" [])
  | VCon { con; name = "posterior-upper-tail-v1"; args = [ VReal max_mass ] }
    when is_constructor store "posterior-upper-tail-v1" con
         && Float.is_finite max_mass && max_mass >= 0.0 && max_mass < 1.0 ->
      Ok (form "posterior-upper-tail-v1" [ lit_real max_mass ])
  | VCon { name = "posterior-upper-tail-v1"; _ } ->
      Error "E1546: UpperTail max-mass must be finite and satisfy 0 <= max-mass < 1"
  | _ -> Error "E1546: unsupported posterior projection rule"

let select_risk store (weights : Infer_dist.risk_weights) (belief : belief) rule =
  match rule with
  | VCon { con; name = "posterior-worst-case-v1"; args = [] }
    when is_constructor store "posterior-worst-case-v1" con ->
      Ok
        (if positive weights.Infer_dist.forbidden then 3
         else if positive weights.high then 2
         else if positive weights.medium then 1
         else 0)
  | VCon { con; name = "posterior-upper-tail-v1"; args = [ VReal max_mass ] }
    when is_constructor store "posterior-upper-tail-v1" con
         && Float.is_finite max_mass && max_mass >= 0.0 && max_mass < 1.0 ->
      if positive weights.forbidden then Ok 3
      else
        let low_tail = belief.medium +. belief.high in
        if low_tail <= max_mass then Ok 0 else if belief.high <= max_mass then Ok 1 else Ok 2
  | VCon { name = "posterior-upper-tail-v1"; _ } ->
      Error "E1546: UpperTail max-mass must be finite and satisfy 0 <= max-mass < 1"
  | _ -> Error "E1546: unsupported posterior projection rule"

let exact_result_code exact =
  form "posterior-exact-result-v1"
    [
      hash_code exact.posterior_id;
      hash_code exact.call_id;
      hash_code exact.model_id;
      hash_code exact.semantics_id;
      exact_config_code exact.max_branches;
      hash_code exact.config_hash;
      exact.source_evidence;
      hash_code exact.evidence_hash;
      weights_code exact.weights;
      belief_code exact.belief;
      positive_support_code exact.positive_support;
      branch_accounting_code exact.branches;
    ]

let projection_code ~projection_id ~baseline_id ~posterior_id ~rule_code ~effective_risk =
  form "posterior-risk-projection-v1"
    [
      hash_code projection_id;
      hash_code baseline_id;
      hash_code posterior_id;
      rule_code;
      form effective_risk [];
    ]

let parse_baseline = function
  | VCon
      {
        name = "governance-assessment-v0";
        args =
          [
            version;
            (VCon { name = risk; args = []; _ } as risk_value);
            VReal confidence;
            reasons;
            VCode evidence;
          ];
        _;
      } -> (
      match risk_rank risk with
      | Some rank -> Ok (version, rank, risk_value, confidence, reasons, evidence)
      | None -> Error "E1546: baseline carries an unknown Risk")
  | _ -> Error "E1546: baseline is not GovernanceAssessmentV0"

let project_exact ctx call baseline exact_value rule =
  let store = Eval.store ctx in
  let ( let* ) = Result.bind in
  let* call_id =
    match validate_call ctx call with
    | Ok (VHash call_id) -> Ok call_id
    | Ok value -> Error ("E1546: validated Call returned a non-hash identity: " ^ Value.show value)
    | Error message -> Error message
  in
  let* _ = validate_assessment ctx baseline in
  let* exact = parse_exact_result store exact_value in
  let* () =
    if Hash.equal call_id exact.call_id then Ok ()
    else Error "E1546: exact posterior Call identity does not match the projected Call"
  in
  let* () =
    if Hash.equal exact.semantics_id (code_hash exact_semantics_code) then Ok ()
    else Error "E1546: exact inference handler semantics identity mismatch"
  in
  let* () =
    if Hash.equal exact.config_hash (code_hash (exact_config_code exact.max_branches)) then Ok ()
    else Error "E1546: exact handler configuration hash mismatch"
  in
  let* () =
    if Hash.equal exact.evidence_hash (code_hash exact.source_evidence) then Ok ()
    else Error "E1546: exact source-evidence hash mismatch"
  in
  let* () =
    if exact.branches.completed <= exact.max_branches then Ok ()
    else Error "E1546: exact branch accounting exceeds the configured budget"
  in
  let* () =
    if
      exact.positive_support.low = positive exact.weights.low
      && exact.positive_support.medium = positive exact.weights.medium
      && exact.positive_support.high = positive exact.weights.high
      && exact.positive_support.forbidden = positive exact.weights.forbidden
    then Ok ()
    else Error "E1546: exact positive-support accounting disagrees with raw weights"
  in
  let reconstructed =
    Infer_dist.
      {
        weights = exact.weights;
        positive_support = exact.positive_support;
        branches = exact.branches;
      }
  in
  let* belief = normalize reconstructed in
  let* () =
    if same_belief belief exact.belief then Ok ()
    else Error "E1546: carried normalized belief disagrees bit-for-bit with raw weights"
  in
  let subject =
    exact_result_subject ~call_id:exact.call_id ~model_id:exact.model_id
      ~semantics_id:exact.semantics_id ~config_hash:exact.config_hash
      ~evidence_hash:exact.evidence_hash ~weights:exact.weights ~belief
  in
  let* () =
    if Hash.equal exact.posterior_id (code_hash subject) then Ok ()
    else Error "E1546: exact posterior identity mismatch"
  in
  let* rule_form = rule_code store rule in
  let* posterior_rank = select_risk store exact.weights belief rule in
  let* version, baseline_rank, _, confidence, reasons, baseline_evidence =
    parse_baseline baseline
  in
  let* () =
    if String.equal baseline_evidence.Form.head "posterior-risk-evidence-v1" then
      Error "E1546: v1 does not define composition of two posterior wrappers"
    else Ok ()
  in
  let* baseline_id = assessment_id ctx baseline in
  let effective_rank = max baseline_rank posterior_rank in
  let effective_name = risk_name effective_rank in
  let* effective_risk = risk_value store effective_name |> Result.map_error Runtime_err.to_string in
  let projection_subject =
    form "posterior-risk-projection-v1"
      [ hash_code baseline_id; hash_code exact.posterior_id; rule_form; form effective_name [] ]
  in
  let projection_id = code_hash projection_subject in
  let* baseline_assessment_code = assessment_code ctx baseline in
  let projection_form =
    projection_code ~projection_id ~baseline_id ~posterior_id:exact.posterior_id
      ~rule_code:rule_form ~effective_risk:effective_name
  in
  let evidence =
    form "posterior-risk-evidence-v1"
      [ baseline_assessment_code; exact_result_code exact; projection_form ]
  in
  let* assessment =
    constructor store "governance-assessment-v0"
      [ version; effective_risk; VReal confidence; reasons; VCode evidence ]
    |> Result.map_error Runtime_err.to_string
  in
  let* _ = validate_assessment ctx assessment in
  let* projection =
    constructor store "posterior-risk-projection-v1"
      [ VHash projection_id; VHash baseline_id; VHash exact.posterior_id; rule; effective_risk ]
    |> Result.map_error Runtime_err.to_string
  in
  constructor store "posterior-projected-assessment-v1" [ assessment; projection ]
  |> Result.map_error Runtime_err.to_string

type exact_replay = {
  call_id : Hash.t;
  posterior_id : Hash.t;
  projection_id : Hash.t;
  assessment_id : Hash.t;
  assessment_code : Form.t;
}

let replay_exact ctx ~builtin_signatures ~model_ref ~config ~source_evidence ~call ~baseline ~rule =
  let store = Eval.store ctx in
  let ( let* ) = Result.bind in
  let* exact = run_exact ctx ~builtin_signatures model_ref config source_evidence call in
  let* parsed_exact = parse_exact_result store exact in
  let* projected = project_exact ctx call baseline exact rule in
  match projected with
  | VCon
      {
        con;
        name = "posterior-projected-assessment-v1";
        args =
          [
            assessment;
            VCon
              {
                con = projection_con;
                name = "posterior-risk-projection-v1";
                args =
                  [
                    VHash projection_id;
                    _baseline_id;
                    VHash projected_posterior_id;
                    _rule;
                    _effective_risk;
                  ];
              };
          ];
      }
    when is_constructor store "posterior-projected-assessment-v1" con
         && is_constructor store "posterior-risk-projection-v1" projection_con ->
      if not (Hash.equal parsed_exact.posterior_id projected_posterior_id) then
        Error "E1546: projected posterior identity disagrees with the exact replay"
      else
        let* assessment_id = assessment_id ctx assessment in
        let* assessment_code = assessment_code ctx assessment in
        Ok
          {
            call_id = parsed_exact.call_id;
            posterior_id = parsed_exact.posterior_id;
            projection_id;
            assessment_id;
            assessment_code;
          }
  | _ -> Error "E1546: exact projection returned a malformed trusted carrier"

let project_exact_builtin ctx args =
  let store = Eval.store ctx in
  match args with
  | [ call; baseline; exact; rule ] ->
      language_result store (project_exact ctx call baseline exact rule)
  | _ -> type_error "posterior.project-exact-v1" args

let sampled_belief store posterior =
  let ( let* ) = Result.bind in
  let released name = lookup store Resolve.KCon name |> Result.map_error Runtime_err.to_string in
  let* low_con = released "low" in
  let* medium_con = released "medium" in
  let* high_con = released "high" in
  let* forbidden_con = released "forbidden" in
  let add prior probability =
    let total = prior +. probability in
    if finite_unit probability && Float.is_finite total then Ok (canonical_zero total)
    else Error "E1547: approximate inference produced invalid empirical masses"
  in
  let rec fold belief = function
    | [] -> Ok belief
    | (VCon { con; args = []; _ }, probability) :: rest when Hash.equal con low_con ->
        let* low = add belief.low probability in
        fold { belief with low } rest
    | (VCon { con; args = []; _ }, probability) :: rest when Hash.equal con medium_con ->
        let* medium = add belief.medium probability in
        fold { belief with medium } rest
    | (VCon { con; args = []; _ }, probability) :: rest when Hash.equal con high_con ->
        let* high = add belief.high probability in
        fold { belief with high } rest
    | (VCon { con; args = []; _ }, probability) :: rest when Hash.equal con forbidden_con ->
        let* forbidden = add belief.forbidden probability in
        fold { belief with forbidden } rest
    | (value, _) :: _ ->
        Error ("E1547: approximate risk model returned a non-Risk value: " ^ Value.show value)
  in
  fold { low = 0.0; medium = 0.0; high = 0.0; forbidden = 0.0 } posterior.Infer_dist.entries

let sample_evidence ctx ~builtin_signatures model_ref config source_evidence call =
  let store = Eval.store ctx in
  let ( let* ) = Result.bind in
  let* model_id = parse_model_ref store model_ref in
  let* samples, seed = parse_approximate_config store config in
  let* evidence =
    match source_evidence with
    | VCode evidence -> Ok evidence
    | _ -> Error "E1547: approximate source evidence must be Code"
  in
  let* call_id =
    match validate_call ctx call with
    | Ok (VHash call_id) -> Ok call_id
    | Ok value -> Error ("E1547: validated Call returned a non-hash identity: " ^ Value.show value)
    | Error message -> Error message
  in
  let* () = check_model_signature store builtin_signatures model_id in
  let* model = model_function ctx model_id in
  let* posterior =
    match
      Infer_dist.likelihood_weighting ctx ~seed ~samples (fun () ->
          Eval.apply_state ctx model [ call ])
    with
    | Ok posterior -> Ok posterior
    | Error diagnostics ->
        Error ("E1547: approximate risk inference failed: " ^ diagnostic_text diagnostics)
  in
  let* normalized = sampled_belief store posterior in
  let* () =
    if
      List.for_all finite_unit
        [ normalized.low; normalized.medium; normalized.high; normalized.forbidden ]
    then Ok ()
    else Error "E1547: approximate inference produced invalid empirical masses"
  in
  let semantics_id = code_hash approximate_semantics_code in
  let config_hash = code_hash (approximate_config_code samples seed) in
  let evidence_hash = code_hash evidence in
  let subject =
    form "non-authorizing-approximate-risk-evidence-v1"
      [
        hash_code call_id;
        hash_code model_id;
        hash_code semantics_id;
        hash_code config_hash;
        hash_code evidence_hash;
        belief_code normalized;
      ]
  in
  let evidence_id = code_hash subject in
  let* belief = belief_value store normalized |> Result.map_error Runtime_err.to_string in
  constructor store "non-authorizing-approximate-risk-evidence-v1"
    [
      VHash evidence_id;
      VHash call_id;
      VHash model_id;
      VHash semantics_id;
      config;
      VHash config_hash;
      source_evidence;
      VHash evidence_hash;
      belief;
    ]
  |> Result.map_error Runtime_err.to_string

let sample_evidence_builtin ctx ~builtin_signatures args =
  let store = Eval.store ctx in
  match args with
  | [ model_ref; config; source_evidence; call ] ->
      language_result store
        (sample_evidence ctx ~builtin_signatures model_ref config source_evidence call)
  | _ -> type_error "posterior.sample-evidence-v1" args
