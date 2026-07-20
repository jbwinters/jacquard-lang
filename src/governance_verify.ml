(** See {!Governance_verify}. *)

type authority =
  | Effect of Hash.t
  | Resource of { effect_id : Hash.t; scope : string; configuration : Hash.t }

type identity_claim = { carried : Hash.t; canonical_subject : Form.t; meta : Meta.t }
type term_ref = { hash : Hash.t; label : string; meta : Meta.t }

type proposal_binding = {
  identity : identity_claim;
  call_id : Hash.t option;
  policy_id : Hash.t option;
  assessment_id : Hash.t option;
  authority : authority list option;
  serialized : Form.t list;
  meta : Meta.t;
}

type action_atom = Raw of { effect_id : Hash.t; resources : authority list } | Forward of Hash.t
type flow_kind = Live_execute | Live_refuse | Dry_simulated | Dry_refuse
type flow_step = Invoke_action | Record_completion | Consume_resume
type flow = { kind : flow_kind; gate : Hash.t; steps : flow_step list; meta : Meta.t }

type lineage =
  | Original
  | Unchanged_forward of { previous_call_id : Hash.t; current_call_id : Hash.t }
  | Transformed_forward of {
      previous_call_id : Hash.t;
      current_call_id : Hash.t;
      parent_call_id : Hash.t option;
    }

type operation = {
  operation_id : Hash.t;
  frozen_authority : authority list;
  call_authority : authority list;
  proposal_authority : authority list;
  call : identity_claim;
  bound_policy : identity_claim;
  assessment : identity_claim;
  proposal : proposal_binding;
  serialized_call_data : Form.t list;
  normalizer : term_ref;
  summarizer : term_ref;
  action : action_atom list;
  live_flows : flow list option;
  dry_flows : flow list option;
  lineage : lineage;
  meta : Meta.t;
}

type sequence_contract = {
  owner_count : int;
  nested_owner_count : int;
  owner_token : int;
  layer_tokens : int list;
  meta : Meta.t;
}

type contract = {
  version : string;
  facade_effect : Hash.t;
  operations : operation list;
  governed_reachable_effects : Hash.t list;
  sequence : sequence_contract;
  meta : Meta.t;
}

type operation_report = {
  operation_id : Hash.t;
  authority : authority list;
  call_id : Hash.t;
  proposal_id : Hash.t;
}

type report = { version : string; facade_effect : Hash.t; operations : operation_report list }

let version = "governance-verifier-v0"
let code_hash form = Hash.of_string (Printer.print_compact form)

let diagnostic_codes =
  [
    ("E1400", "governance verifier environment or IR version mismatch");
    ("E1401", "facade declaration or operation-mode mismatch");
    ("E1402", "missing, duplicate, or unknown live/dry operation coverage");
    ("E1403", "noncanonical gate or disposition-flow ordering");
    ("E1404", "invalid audit sequence owner or token provenance");
    ("E1405", "impure call normalizer or outcome summarizer");
    ("E1406", "canonical governance identity mismatch");
    ("E1407", "raw-authority envelope mismatch or unexpandable action");
    ("E1408", "gate-control effect found inside a raw action");
    ("E1409", "secret value or generic inspection in review/audit data");
    ("E1410", "incomplete or inconsistent Ask proposal binding");
    ("E1411", "invalid unchanged or transformed call lineage");
    ("E1412", "Eval reachable from a governed body or action");
  ]

type vocabulary = {
  judge : Hash.t;
  governance_approval : Hash.t;
  audit : Hash.t;
  state : Hash.t;
  eval : Hash.t;
  gate_live : Hash.t;
  gate_dry : Hash.t;
  make_call : Hash.t;
  debug_inspect : Hash.t;
  result_type : Hash.t;
  governance_call : Hash.t;
  outcome_summary : Hash.t;
  secret_constructor : Hash.t;
}

let span meta = Meta.span meta

let diagnostic_summary code =
  match List.assoc_opt code diagnostic_codes with
  | Some meaning -> String.capitalize_ascii meaning
  | None -> "Governance verification failed"

let diagnostic meta code cause =
  Diag.error ?span:(span meta) ~domain:Governance ~code ~summary:(diagnostic_summary code) ~cause
    ~next_step:"Restore the canonical governed structure described by this diagnostic."
    ~contrast:None ()

let hex hash = Hash.to_hex hash

let pinned_hash name spelling =
  match Hash.of_canonical_hex spelling with
  | Some hash -> hash
  | None -> invalid_arg ("Bug_governance verifier has malformed pinned hash for " ^ name)

let gate_live_v0 =
  pinned_hash "governance.gate-live"
    "16503e4a588c7611487371fc49ee0e0ec7e3f809178ce30f2cab0162fea7ce8b"

let gate_dry_v0 =
  pinned_hash "governance.gate-dry"
    "a87cd8a1b13312df7517f93d6caed82b801f7651ae482bf9566f2501863f5891"

let make_call_v0 =
  pinned_hash "governance.make-call"
    "930cf869936a5c8d385e0e444eb331e343e37f9712eb4740d733f40aa717032f"

let debug_inspect_v0 =
  pinned_hash "debug.inspect" "5a620819e5f501da9a9959118176b547419c4bb0033d8b48ede4f9bd30cc2580"

let governance_call_v0 =
  pinned_hash "governance-call" "20824137b34985dabf9e6bb0c20cf9987c1ca93b5cdd8d1da60cbc69550efc27"

let result_type_v0 =
  pinned_hash "result type" "5552731cc63f81199617f3ecf4e4a8c14748c303d6ce78ce5b0f05f3026ad8db"

let outcome_summary_v0 =
  pinned_hash "governance-outcome-summary"
    "7a564b18a2535d29933ec1db4003776b9b9db65130d4dd4dc31c7db88f064aee"

let secret_type_v0 =
  pinned_hash "secret type" "0994b74f0147062152d3620195f694484e2751d27129217f4385ac3d0fd1b54e"

let lookup store meta ~kind name =
  match Store.lookup_kind store name kind with
  | Some entry -> Ok entry.Resolve.hash
  | None ->
      Error
        (diagnostic meta "E1400"
           (Printf.sprintf "governance verifier requires the exact `%s` prelude identity" name))

let lookup_pinned store meta ~kind name expected =
  match lookup store meta ~kind name with
  | Ok actual when Hash.equal actual expected -> Ok actual
  | Ok actual ->
      Error
        (diagnostic meta "E1400"
           (Printf.sprintf
              "governance verifier name `%s` resolves to #%s instead of pinned identity #%s" name
              (hex actual) (hex expected)))
  | Error diagnostic -> Error diagnostic

let lookup_canonical_effect store meta name =
  match lookup store meta ~kind:Resolve.KEffect name with
  | Ok actual -> (
      match Effect_registry.find_canonical actual with
      | Some metadata when String.equal metadata.Effect_registry.index_name name -> Ok actual
      | Some metadata ->
          Error
            (diagnostic meta "E1400"
               (Printf.sprintf
                  "governance verifier name `%s` resolves to canonical effect `%s`, not `%s`" name
                  metadata.Effect_registry.index_name name))
      | None ->
          Error
            (diagnostic meta "E1400"
               (Printf.sprintf
                  "governance verifier name `%s` does not resolve to its frozen effect identity"
                  name)))
  | Error diagnostic -> Error diagnostic

let resolve_vocabulary store meta =
  let ( let* ) = Result.bind in
  let* judge = lookup_canonical_effect store meta "judge" in
  let* governance_approval = lookup_canonical_effect store meta "governance-approval-v1" in
  let* audit = lookup_canonical_effect store meta "audit" in
  let* state = lookup_canonical_effect store meta "state" in
  let* eval = lookup_canonical_effect store meta "eval" in
  let* gate_live =
    lookup_pinned store meta ~kind:Resolve.KTerm "governance.gate-live" gate_live_v0
  in
  let* gate_dry = lookup_pinned store meta ~kind:Resolve.KTerm "governance.gate-dry" gate_dry_v0 in
  let* make_call =
    lookup_pinned store meta ~kind:Resolve.KTerm "governance.make-call" make_call_v0
  in
  let* governance_call =
    lookup_pinned store meta ~kind:Resolve.KType "governance-call" governance_call_v0
  in
  let* result_type = lookup_pinned store meta ~kind:Resolve.KType "result" result_type_v0 in
  let* outcome_summary =
    lookup_pinned store meta ~kind:Resolve.KType "governance-outcome-summary" outcome_summary_v0
  in
  let* secret_type = lookup_pinned store meta ~kind:Resolve.KType "secret" secret_type_v0 in
  Ok
    {
      judge;
      governance_approval;
      audit;
      state;
      eval;
      gate_live;
      gate_dry;
      make_call;
      debug_inspect = debug_inspect_v0;
      result_type;
      governance_call;
      outcome_summary;
      secret_constructor = Canon.con_hash secret_type 0;
    }

let authority_equal left right =
  match (left, right) with
  | Effect a, Effect b -> Hash.equal a b
  | Resource a, Resource b ->
      Hash.equal a.effect_id b.effect_id
      && String.equal a.scope b.scope
      && Hash.equal a.configuration b.configuration
  | Effect _, Resource _ | Resource _, Effect _ -> false

let authority_lists_equal left right =
  List.length left = List.length right && List.for_all2 authority_equal left right

let show_authority = function
  | Effect effect_id -> "Effect(#" ^ hex effect_id ^ ")"
  | Resource { effect_id; scope; configuration } ->
      Printf.sprintf "Resource(#%s,%S,#%s)" (hex effect_id) scope (hex configuration)

let show_authorities values = "[" ^ String.concat ", " (List.map show_authority values) ^ "]"

let identity_diagnostic label claim =
  let recomputed = code_hash claim.canonical_subject in
  if Hash.equal claim.carried recomputed then None
  else
    Some
      (diagnostic claim.meta "E1406"
         (Printf.sprintf "%s carries #%s but its canonical Code recomputes to #%s" label
            (hex claim.carried) (hex recomputed)))

let rec form_contains_secret secret_constructor form =
  String.equal form.Form.head "secret-opaque"
  || List.exists
       (function
         | Form.Hash hash -> Hash.equal hash secret_constructor
         | Form.F nested -> form_contains_secret secret_constructor nested
         | Form.Int _ | Form.Real _ | Form.Text _ | Form.Sym _ -> false)
       form.Form.args

let rec expr_refs (expression : Kernel.expr) =
  match expression.Kernel.it with
  | Kernel.Ref (hash, kind) -> [ (hash, kind) ]
  | Kernel.Lam (_, body) | Kernel.Ann (body, _) | Kernel.Unquote body -> expr_refs body
  | Kernel.App (fn, args) -> expr_refs fn @ List.concat_map expr_refs args
  | Kernel.Let { value; body; _ } -> expr_refs value @ expr_refs body
  | Kernel.Match (scrutinee, clauses) ->
      expr_refs scrutinee @ List.concat_map (fun clause -> expr_refs clause.Kernel.cbody) clauses
  | Kernel.Tuple items -> List.concat_map expr_refs items
  | Kernel.Handle { body; ret; ops } ->
      expr_refs body @ expr_refs ret.Kernel.rbody
      @ List.concat_map (fun clause -> expr_refs clause.Kernel.obody) ops
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Quote _ | Kernel.GroupRef _ -> []

let member_hashes declaration =
  match Canon.hash_decl declaration with
  | Ok hashes -> List.map snd hashes.Canon.named
  | Error _ -> []

let reachable_term_ref store ~start ~target =
  let visited = ref [] in
  let rec visit hash =
    if Hash.equal hash target then true
    else if List.exists (Hash.equal hash) !visited then false
    else
      let () = visited := hash :: !visited in
      match Store.locate_internal store hash with
      | Error _ -> false
      | Ok { Store.decl; role = Store.Member index; _ } -> (
          match decl.Kernel.it with
          | Kernel.DefTerm bindings ->
              let group = member_hashes decl in
              let body = (List.nth bindings index).Kernel.value in
              let direct = expr_refs body in
              List.exists (fun (reference, kind) -> kind = Kernel.Term && visit reference) direct
              ||
              let rec group_refs expression =
                match expression.Kernel.it with
                | Kernel.GroupRef member -> (
                    match List.nth_opt group member with
                    | Some reference -> visit reference
                    | None -> false)
                | Kernel.Lam (_, body) | Kernel.Ann (body, _) | Kernel.Unquote body ->
                    group_refs body
                | Kernel.App (fn, args) -> group_refs fn || List.exists group_refs args
                | Kernel.Let { value; body; _ } -> group_refs value || group_refs body
                | Kernel.Match (scrutinee, clauses) ->
                    group_refs scrutinee
                    || List.exists (fun clause -> group_refs clause.Kernel.cbody) clauses
                | Kernel.Tuple items -> List.exists group_refs items
                | Kernel.Handle { body; ret; ops } ->
                    group_refs body || group_refs ret.Kernel.rbody
                    || List.exists (fun clause -> group_refs clause.Kernel.obody) ops
                | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.Quote _ -> false
              in
              group_refs body
          | Kernel.DefType _ | Kernel.DefEffect _ -> false)
      | Ok _ -> false
  in
  visit start

let row_is_closed_pure row =
  let row = Types.repr_row row in
  row.Types.effects = [] && row.Types.tail = Types.RClosed

let rec type_has_only_closed_pure_arrows ty =
  match Types.repr ty with
  | Types.TCon (_, arguments) -> List.for_all type_has_only_closed_pure_arrows arguments
  | Types.TTuple items -> List.for_all type_has_only_closed_pure_arrows items
  | Types.TArrow (parameters, row, result) ->
      row_is_closed_pure row
      && List.for_all type_has_only_closed_pure_arrows parameters
      && type_has_only_closed_pure_arrows result
  | Types.TResume (parameter, row, result) ->
      row_is_closed_pure row
      && type_has_only_closed_pure_arrows parameter
      && type_has_only_closed_pure_arrows result
  | Types.TVariadicArrow (parameter, row, result) ->
      row_is_closed_pure row
      && type_has_only_closed_pure_arrows parameter
      && type_has_only_closed_pure_arrows result
  | Types.TVar _ | Types.TSkolem _ -> true

let result_has_identity ~result_type ~expected ~allow_result = function
  | Types.TArrow (_, _, result) | Types.TVariadicArrow (_, _, result) -> (
      match Types.repr result with
      | Types.TCon (actual, []) -> Hash.equal actual expected
      | Types.TCon (actual, [ _error; success ]) when allow_result && Hash.equal actual result_type
        -> (
          match Types.repr success with
          | Types.TCon (actual, []) -> Hash.equal actual expected
          | _ -> false)
      | _ -> false)
  | _ -> false

let check_pure_term checker ~result_type ~expected_result ~expected_name ~allow_result term =
  match Check.force_term checker term.hash with
  | Error diagnostics ->
      [
        diagnostic term.meta "E1405"
          (Printf.sprintf "%s cannot be checked: %s" term.label
             (String.concat "; " (List.map Diag.to_cause_string diagnostics)));
      ]
  | Ok scheme -> (
      let inferred = Types.repr scheme.Types.ty in
      match inferred with
      | (Types.TArrow _ | Types.TVariadicArrow _)
        when type_has_only_closed_pure_arrows inferred
             && result_has_identity ~result_type ~expected:expected_result ~allow_result inferred ->
          []
      | Types.TArrow _ | Types.TVariadicArrow _ ->
          [
            diagnostic term.meta "E1405"
              (Printf.sprintf
                 "%s must contain only closed pure arrows and return exact %s, found %s" term.label
                 expected_name
                 (Check.show_scheme checker scheme));
          ]
      | _ ->
          [
            diagnostic term.meta "E1405"
              (Printf.sprintf "%s must be a function, found %s" term.label
                 (Check.show_scheme checker scheme));
          ])

let expected_steps = function
  | Live_execute -> [ Invoke_action; Record_completion; Consume_resume ]
  | Live_refuse | Dry_simulated | Dry_refuse -> [ Consume_resume ]

let flow_name = function
  | Live_execute -> "live ExecuteLive"
  | Live_refuse -> "live RefuseLive"
  | Dry_simulated -> "dry Simulated"
  | Dry_refuse -> "dry RefuseDry"

let flow_equal left right = left = right

let validate_flow vocabulary flow =
  let expected_gate =
    match flow.kind with
    | Live_execute | Live_refuse -> vocabulary.gate_live
    | Dry_simulated | Dry_refuse -> vocabulary.gate_dry
  in
  let diagnostics = ref [] in
  if not (Hash.equal flow.gate expected_gate) then
    diagnostics :=
      diagnostic flow.meta "E1403"
        (Printf.sprintf "%s branch uses gate #%s instead of canonical gate #%s"
           (flow_name flow.kind) (hex flow.gate) (hex expected_gate))
      :: !diagnostics;
  let expected = expected_steps flow.kind in
  if not (flow_equal flow.steps expected) then
    diagnostics :=
      diagnostic flow.meta "E1403"
        (Printf.sprintf "%s branch has noncanonical action/completion/resume ordering"
           (flow_name flow.kind))
      :: !diagnostics;
  List.rev !diagnostics

let kinds_equal left right = List.length left = List.length right && List.for_all2 ( = ) left right

let validate_flows vocabulary mode meta flows =
  match flows with
  | None ->
      [
        diagnostic meta "E1402"
          (Printf.sprintf "facade operation is missing its %s clause"
             (match mode with `Live -> "live" | `Dry -> "dry-run"));
      ]
  | Some flows ->
      let expected =
        match mode with
        | `Live -> [ Live_execute; Live_refuse ]
        | `Dry -> [ Dry_simulated; Dry_refuse ]
      in
      let actual = List.map (fun flow -> flow.kind) flows in
      let coverage =
        if kinds_equal actual expected then []
        else
          [
            diagnostic meta "E1402"
              (Printf.sprintf "%s clause must cover each canonical disposition exactly once"
                 (match mode with `Live -> "live" | `Dry -> "dry-run"));
          ]
      in
      coverage @ List.concat_map (validate_flow vocabulary) flows

let validate_lineage (operation : operation) =
  let meta = operation.meta in
  match operation.lineage with
  | Original -> []
  | Unchanged_forward { previous_call_id; current_call_id } ->
      if
        Hash.equal previous_call_id current_call_id
        && Hash.equal current_call_id operation.call.carried
      then []
      else
        [
          diagnostic meta "E1411"
            "unchanged forwarding must retain the previous Call ID as the operation's exact \
             carried Call";
        ]
  | Transformed_forward { previous_call_id; current_call_id; parent_call_id } ->
      if
        (not (Hash.equal previous_call_id current_call_id))
        && Hash.equal current_call_id operation.call.carried
        &&
        match parent_call_id with
        | Some parent -> Hash.equal previous_call_id parent
        | None -> false
      then []
      else
        [
          diagnostic meta "E1411"
            "a transformed call must carry its new Call ID and parent-call-id = \
             Some(previous-call-id)";
        ]

let validate_proposal (operation : operation) =
  let proposal = operation.proposal in
  let complete =
    match (proposal.call_id, proposal.policy_id, proposal.assessment_id, proposal.authority) with
    | Some call_id, Some policy_id, Some assessment_id, Some authority ->
        Hash.equal call_id operation.call.carried
        && Hash.equal policy_id operation.bound_policy.carried
        && Hash.equal assessment_id operation.assessment.carried
        && authority_lists_equal authority operation.frozen_authority
    | _ -> false
  in
  if complete then []
  else
    [
      diagnostic proposal.meta "E1410"
        "Ask proposal must bind the exact Call, BoundPolicy, assessment, and frozen authority";
    ]

let validate_sequence sequence =
  if
    sequence.owner_count = 1 && sequence.nested_owner_count = 0 && sequence.layer_tokens <> []
    && List.for_all (( = ) sequence.owner_token) sequence.layer_tokens
  then []
  else
    [
      diagnostic sequence.meta "E1404"
        "one with-sequence owner must surround the stream and pass its exact token to every layer";
    ]

let validate_facade store (contract : contract) =
  match Store.locate store contract.facade_effect with
  | Error diagnostics ->
      [
        diagnostic contract.meta "E1401"
          (Printf.sprintf "facade effect cannot be resolved: %s"
             (String.concat "; " (List.map Diag.to_cause_string diagnostics)));
      ]
  | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; role = Store.Whole; _ } ->
      let mode_errors =
        List.filter_map
          (fun operation ->
            if operation.Kernel.op_mode = Kernel.Once then None
            else
              Some
                (diagnostic operation.Kernel.smeta "E1401"
                   (Printf.sprintf "facade operation `%s` must use once mode" operation.op_name)))
          ops
      in
      let expected =
        List.mapi (fun ordinal _ -> Canon.op_hash contract.facade_effect ordinal) ops
      in
      let actual =
        List.map (fun (operation : operation) -> operation.operation_id) contract.operations
      in
      let unique = List.sort_uniq Hash.compare actual in
      let coverage_ok =
        List.length actual = List.length unique
        && List.length expected = List.length actual
        && List.for_all (fun hash -> List.exists (Hash.equal hash) actual) expected
      in
      mode_errors
      @
      if coverage_ok then []
      else
        [
          diagnostic contract.meta "E1402"
            "verifier operation inventory must cover every facade operation exactly once";
        ]
  | Ok _ -> [ diagnostic contract.meta "E1401" "facade identity is not a whole effect declaration" ]

let validate_authorities vocabulary (operations : operation list) (operation : operation) =
  let controls =
    [ vocabulary.state; vocabulary.judge; vocabulary.governance_approval; vocabulary.audit ]
  in
  let diagnostics = ref [] in
  let rec expand visiting = function
    | [] -> []
    | Raw { effect_id; resources } :: rest ->
        if List.exists (Hash.equal effect_id) controls then
          diagnostics :=
            diagnostic operation.meta "E1408"
              (Printf.sprintf "gate-control effect #%s occurs inside the action" (hex effect_id))
            :: !diagnostics;
        if Hash.equal effect_id vocabulary.eval then
          diagnostics :=
            diagnostic operation.meta "E1412" "Eval is prohibited inside a governed action"
            :: !diagnostics;
        List.iter
          (function
            | Resource resource when not (Hash.equal resource.effect_id effect_id) ->
                diagnostics :=
                  diagnostic operation.meta "E1407"
                    "configured Resource evidence must refine its action Effect identity"
                  :: !diagnostics
            | Effect _ ->
                diagnostics :=
                  diagnostic operation.meta "E1407"
                    "raw action resources may contain only Resource evidence, not another Effect"
                  :: !diagnostics
            | Resource _ -> ())
          resources;
        (Effect effect_id :: resources) @ expand visiting rest
    | Forward forwarded :: rest -> (
        match
          List.find_opt
            (fun (candidate : operation) -> Hash.equal candidate.operation_id forwarded)
            operations
        with
        | Some _ when List.exists (Hash.equal forwarded) visiting ->
            diagnostics :=
              diagnostic operation.meta "E1407"
                (Printf.sprintf "action forwarding cycle reaches facade operation #%s"
                   (hex forwarded))
              :: !diagnostics;
            expand visiting rest
        | Some target -> expand (forwarded :: visiting) target.action @ expand visiting rest
        | None ->
            diagnostics :=
              diagnostic operation.meta "E1407"
                (Printf.sprintf "action forwards through unknown facade operation #%s"
                   (hex forwarded))
              :: !diagnostics;
            expand visiting rest)
  in
  let projected = expand [ operation.operation_id ] operation.action in
  let compare label actual =
    if authority_lists_equal operation.frozen_authority actual then ()
    else
      diagnostics :=
        diagnostic operation.meta "E1407"
          (Printf.sprintf "%s authority %s does not equal frozen envelope %s" label
             (show_authorities actual)
             (show_authorities operation.frozen_authority))
        :: !diagnostics
  in
  compare "Call" operation.call_authority;
  compare "Proposal" operation.proposal_authority;
  compare "transitive action" projected;
  List.rev !diagnostics

let make_checker store =
  match Check.make_ctx store with
  | Error diagnostics -> Error diagnostics
  | Ok checker -> (
      match Prelude.builtin_signatures store with
      | Error diagnostics -> Error diagnostics
      | Ok signatures ->
          Check.register_builtin_signatures checker signatures;
          Ok checker)

let validate_operation store checker vocabulary (operations : operation list)
    (operation : operation) =
  let diagnostics = ref [] in
  let add values = diagnostics := !diagnostics @ values in
  List.iter
    (fun (label, claim) ->
      match identity_diagnostic label claim with None -> () | Some value -> add [ value ])
    [
      ("Call", operation.call);
      ("BoundPolicy", operation.bound_policy);
      ("assessment", operation.assessment);
      ("Proposal", operation.proposal.identity);
    ];
  add
    (check_pure_term checker ~result_type:vocabulary.result_type
       ~expected_result:vocabulary.governance_call
       ~expected_name:"GovernanceCall or Result _ GovernanceCall" ~allow_result:true
       operation.normalizer);
  add
    (check_pure_term checker ~result_type:vocabulary.result_type
       ~expected_result:vocabulary.outcome_summary ~expected_name:"GovernanceOutcomeSummary"
       ~allow_result:false operation.summarizer);
  if not (reachable_term_ref store ~start:operation.normalizer.hash ~target:vocabulary.make_call)
  then
    add
      [
        diagnostic operation.normalizer.meta "E1406"
          (operation.normalizer.label ^ " must reach the canonical governance.make-call constructor");
      ];
  if reachable_term_ref store ~start:operation.normalizer.hash ~target:vocabulary.debug_inspect then
    add
      [
        diagnostic operation.normalizer.meta "E1409"
          "call normalizers must not use generic debug.inspect";
      ];
  if reachable_term_ref store ~start:operation.summarizer.hash ~target:vocabulary.debug_inspect then
    add
      [
        diagnostic operation.summarizer.meta "E1409"
          "outcome summarizers must not use generic debug.inspect";
      ];
  let serialized =
    operation.serialized_call_data @ operation.proposal.serialized
    @ [
        operation.call.canonical_subject;
        operation.bound_policy.canonical_subject;
        operation.assessment.canonical_subject;
        operation.proposal.identity.canonical_subject;
      ]
  in
  if List.exists (form_contains_secret vocabulary.secret_constructor) serialized then
    add
      [
        diagnostic operation.meta "E1409"
          "governance review data may serialize SecretRef values but never an opaque Secret value";
      ];
  add (validate_authorities vocabulary operations operation);
  add (validate_proposal operation);
  add (validate_flows vocabulary `Live operation.meta operation.live_flows);
  add (validate_flows vocabulary `Dry operation.meta operation.dry_flows);
  add (validate_lineage operation);
  !diagnostics

let verify store (contract : contract) =
  let environment =
    match (resolve_vocabulary store contract.meta, make_checker store) with
    | Ok vocabulary, Ok checker -> Ok (vocabulary, checker)
    | Error diagnostic, Ok _ -> Error [ diagnostic ]
    | Ok _, Error diagnostics -> Error diagnostics
    | Error diagnostic, Error diagnostics -> Error (diagnostic :: diagnostics)
  in
  match environment with
  | Error diagnostics -> Error diagnostics
  | Ok (vocabulary, checker) -> (
      let diagnostics = ref [] in
      let add values = diagnostics := !diagnostics @ values in
      if not (String.equal contract.version version) then
        add
          [
            diagnostic contract.meta "E1400"
              (Printf.sprintf "unsupported governance verifier IR `%s`; expected `%s`"
                 contract.version version);
          ];
      add (validate_facade store contract);
      add (validate_sequence contract.sequence);
      if List.exists (Hash.equal vocabulary.eval) contract.governed_reachable_effects then
        add
          [
            diagnostic contract.meta "E1412"
              "governed body reaches Eval, including effects discharged by an inner handler";
          ];
      List.iter
        (fun operation ->
          add (validate_operation store checker vocabulary contract.operations operation))
        contract.operations;
      match !diagnostics with
      | _ :: _ as diagnostics -> Error diagnostics
      | [] ->
          Ok
            {
              version = contract.version;
              facade_effect = contract.facade_effect;
              operations =
                List.map
                  (fun (operation : operation) ->
                    {
                      operation_id = operation.operation_id;
                      authority = operation.frozen_authority;
                      call_id = operation.call.carried;
                      proposal_id = operation.proposal.identity.carried;
                    })
                  contract.operations;
            })

module V1 = struct
  type operation_key = { layer_id : int; operation_id : Hash.t }

  type action_atom =
    | Raw of { effect_id : Hash.t; resources : authority list }
    | Forward of operation_key

  type operation = {
    operation_id : Hash.t;
    frozen_authority : authority list;
    call_authority : authority list;
    proposal_authority : authority list;
    call : identity_claim;
    bound_policy : identity_claim;
    assessment : identity_claim;
    proposal : proposal_binding;
    serialized_call_data : Form.t list;
    normalizer : term_ref;
    summarizer : term_ref;
    action : action_atom list;
    live_flows : flow list option;
    lineage : lineage;
    meta : Meta.t;
  }

  type layer = {
    layer_id : int;
    outer_layer_id : int option;
    operations : operation list;
    meta : Meta.t;
  }

  type contract = {
    version : string;
    facade_effect : Hash.t;
    layers : layer list;
    governed_reachable_effects : Hash.t list;
    sequence : sequence_contract;
    meta : Meta.t;
  }

  type operation_report = {
    layer_id : int;
    operation_id : Hash.t;
    authority : authority list;
    call_id : Hash.t;
    proposal_id : Hash.t;
  }

  type report = { version : string; facade_effect : Hash.t; operations : operation_report list }

  let version = "governance-verifier-v1"

  let key_equal (left : operation_key) (right : operation_key) =
    left.layer_id = right.layer_id && Hash.equal left.operation_id right.operation_id

  let find_layer layers layer_id =
    List.find_opt (fun (layer : layer) -> layer.layer_id = layer_id) layers

  let find_operation layers (key : operation_key) =
    match find_layer layers key.layer_id with
    | None -> None
    | Some layer ->
        List.find_opt
          (fun (operation : operation) -> Hash.equal operation.operation_id key.operation_id)
          layer.operations

  let validate_facade store (contract : contract) =
    match Store.locate store contract.facade_effect with
    | Error diagnostics ->
        [
          diagnostic contract.meta "E1401"
            (Printf.sprintf "facade effect cannot be resolved: %s"
               (String.concat "; " (List.map Diag.to_cause_string diagnostics)));
        ]
    | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; role = Store.Whole; _ } ->
        let mode_errors =
          List.filter_map
            (fun operation ->
              if operation.Kernel.op_mode = Kernel.Once then None
              else
                Some
                  (diagnostic operation.Kernel.smeta "E1401"
                     (Printf.sprintf "facade operation `%s` must use once mode" operation.op_name)))
            ops
        in
        let expected =
          List.mapi (fun ordinal _ -> Canon.op_hash contract.facade_effect ordinal) ops
        in
        let layer_errors =
          List.concat_map
            (fun (layer : layer) ->
              let actual =
                List.map (fun (operation : operation) -> operation.operation_id) layer.operations
              in
              let unique = List.sort_uniq Hash.compare actual in
              let coverage_ok =
                List.length actual = List.length unique
                && List.length expected = List.length actual
                && List.for_all (fun hash -> List.exists (Hash.equal hash) actual) expected
              in
              if coverage_ok then []
              else
                [
                  diagnostic layer.meta "E1402"
                    (Printf.sprintf
                       "layer %d operation inventory must cover every facade operation exactly once"
                       layer.layer_id);
                ])
            contract.layers
        in
        mode_errors @ layer_errors
    | Ok _ ->
        [ diagnostic contract.meta "E1401" "facade identity is not a whole effect declaration" ]

  let validate_topology (contract : contract) =
    let diagnostics = ref [] in
    let add meta cause = diagnostics := !diagnostics @ [ diagnostic meta "E1407" cause ] in
    if contract.layers = [] then
      add contract.meta "layer-aware verifier requires at least one layer";
    let ids = List.map (fun (layer : layer) -> layer.layer_id) contract.layers in
    let unique = List.sort_uniq Int.compare ids in
    if List.length ids <> List.length unique then
      add contract.meta "membrane layer IDs must be unique";
    List.iter
      (fun (layer : layer) ->
        match layer.outer_layer_id with
        | Some outer when outer = layer.layer_id ->
            add layer.meta (Printf.sprintf "layer %d cannot forward to itself" layer.layer_id)
        | Some outer when Option.is_none (find_layer contract.layers outer) ->
            add layer.meta
              (Printf.sprintf "layer %d names unknown outer layer %d" layer.layer_id outer)
        | Some _ | None -> ())
      contract.layers;
    let incoming layer_id =
      List.filter
        (fun (candidate : layer) -> candidate.outer_layer_id = Some layer_id)
        contract.layers
    in
    let roots = List.filter (fun (layer : layer) -> incoming layer.layer_id = []) contract.layers in
    let leaves =
      List.filter (fun (layer : layer) -> Option.is_none layer.outer_layer_id) contract.layers
    in
    if List.length roots <> 1 then
      add contract.meta "membrane layers must form one chain with exactly one inner root";
    if List.length leaves <> 1 then
      add contract.meta "membrane layers must form one chain with exactly one raw outer leaf";
    List.iter
      (fun (layer : layer) ->
        let count = List.length (incoming layer.layer_id) in
        if count > 1 then
          add layer.meta
            (Printf.sprintf "layer %d has %d inner predecessors; membrane topology must be linear"
               layer.layer_id count))
      contract.layers;
    (match roots with
    | [ root ] ->
        let rec walk visited (layer : layer) =
          if List.mem layer.layer_id visited then
            add layer.meta (Printf.sprintf "membrane layer cycle reaches layer %d" layer.layer_id)
          else
            match layer.outer_layer_id with
            | None ->
                let visited = layer.layer_id :: visited in
                if List.length visited <> List.length contract.layers then
                  add contract.meta "every membrane layer must be reachable from the inner root"
            | Some outer -> (
                match find_layer contract.layers outer with
                | Some next -> walk (layer.layer_id :: visited) next
                | None -> ())
        in
        walk [] root
    | _ -> ());
    !diagnostics

  let source_layer layers target_id =
    List.find_opt (fun (layer : layer) -> layer.outer_layer_id = Some target_id) layers

  let validate_action_shape facade_effect (layer : layer) (operation : operation) =
    match layer.outer_layer_id with
    | Some outer -> (
        match operation.action with
        | [ Forward target ]
          when target.layer_id = outer && Hash.equal target.operation_id operation.operation_id ->
            []
        | _ ->
            [
              diagnostic operation.meta "E1407"
                (Printf.sprintf
                   "non-leaf layer %d must forward this exact facade operation once to declared \
                    outer layer %d"
                   layer.layer_id outer);
            ])
    | None ->
        if
          operation.action <> []
          && List.for_all (function Raw _ -> true | Forward _ -> false) operation.action
          && not
               (List.exists
                  (function
                    | Raw { effect_id; _ } -> Hash.equal effect_id facade_effect
                    | Forward _ -> false)
                  operation.action)
        then []
        else
          [
            diagnostic operation.meta "E1407"
              (Printf.sprintf
                 "outer leaf layer %d must terminate in nonempty raw actions outside the facade \
                  effect"
                 layer.layer_id);
          ]

  let validate_lineage layers (layer : layer) (operation : operation) =
    match source_layer layers layer.layer_id with
    | None -> (
        match operation.lineage with
        | Original -> []
        | Unchanged_forward _ | Transformed_forward _ ->
            [ diagnostic operation.meta "E1411" "the inner root layer must carry Original lineage" ]
        )
    | Some source -> (
        match
          List.find_opt
            (fun (candidate : operation) ->
              Hash.equal candidate.operation_id operation.operation_id)
            source.operations
        with
        | None ->
            [
              diagnostic operation.meta "E1411"
                "forwarded call lineage has no matching operation in the immediate inner layer";
            ]
        | Some previous -> (
            let previous_id = previous.call.carried in
            let current_id = operation.call.carried in
            if Hash.equal previous_id current_id then
              match operation.lineage with
              | Unchanged_forward { previous_call_id; current_call_id }
                when Hash.equal previous_call_id previous_id
                     && Hash.equal current_call_id current_id ->
                  []
              | Original | Unchanged_forward _ | Transformed_forward _ ->
                  [
                    diagnostic operation.meta "E1411"
                      "unchanged forwarding must directly bind the immediate inner Call ID to the \
                       identical current Call ID";
                  ]
            else
              match operation.lineage with
              | Transformed_forward { previous_call_id; current_call_id; parent_call_id }
                when Hash.equal previous_call_id previous_id
                     && Hash.equal current_call_id current_id
                     &&
                     match parent_call_id with
                     | Some parent -> Hash.equal previous_id parent
                     | None -> false ->
                  []
              | Original | Unchanged_forward _ | Transformed_forward _ ->
                  [
                    diagnostic operation.meta "E1411"
                      "transformed forwarding must directly bind the immediate inner Call ID as \
                       parent of the current Call ID";
                  ]))

  let validate_proposal (operation : operation) =
    let proposal = operation.proposal in
    let complete =
      match (proposal.call_id, proposal.policy_id, proposal.assessment_id, proposal.authority) with
      | Some call_id, Some policy_id, Some assessment_id, Some authority ->
          Hash.equal call_id operation.call.carried
          && Hash.equal policy_id operation.bound_policy.carried
          && Hash.equal assessment_id operation.assessment.carried
          && authority_lists_equal authority operation.frozen_authority
      | _ -> false
    in
    if complete then []
    else
      [
        diagnostic proposal.meta "E1410"
          "Ask proposal must bind the exact Call, BoundPolicy, assessment, and frozen authority";
      ]

  let validate_authorities vocabulary layers (layer : layer) (operation : operation) =
    let controls =
      [ vocabulary.state; vocabulary.judge; vocabulary.governance_approval; vocabulary.audit ]
    in
    let diagnostics = ref [] in
    let add code cause = diagnostics := !diagnostics @ [ diagnostic operation.meta code cause ] in
    let rec expand visiting = function
      | [] -> []
      | Raw { effect_id; resources } :: rest ->
          if List.exists (Hash.equal effect_id) controls then
            add "E1408"
              (Printf.sprintf "gate-control effect #%s occurs inside the action" (hex effect_id));
          if Hash.equal effect_id vocabulary.eval then
            add "E1412" "Eval is prohibited inside a governed action";
          List.iter
            (function
              | Resource resource when not (Hash.equal resource.effect_id effect_id) ->
                  add "E1407" "configured Resource evidence must refine its action Effect identity"
              | Effect _ ->
                  add "E1407"
                    "raw action resources may contain only Resource evidence, not another Effect"
              | Resource _ -> ())
            resources;
          (Effect effect_id :: resources) @ expand visiting rest
      | Forward target :: rest -> (
          if List.exists (key_equal target) visiting then (
            add "E1407"
              (Printf.sprintf "action forwarding cycle reaches layer %d facade operation #%s"
                 target.layer_id (hex target.operation_id));
            expand visiting rest)
          else
            match find_operation layers target with
            | Some target_operation ->
                expand (target :: visiting) target_operation.action @ expand visiting rest
            | None ->
                add "E1407"
                  (Printf.sprintf "action forwards through unknown layer %d facade operation #%s"
                     target.layer_id (hex target.operation_id));
                expand visiting rest)
    in
    let start = { layer_id = layer.layer_id; operation_id = operation.operation_id } in
    let projected = expand [ start ] operation.action in
    let compare label actual =
      if not (authority_lists_equal operation.frozen_authority actual) then
        add "E1407"
          (Printf.sprintf "%s authority %s does not equal frozen envelope %s" label
             (show_authorities actual)
             (show_authorities operation.frozen_authority))
    in
    compare "Call" operation.call_authority;
    compare "Proposal" operation.proposal_authority;
    compare "transitive action" projected;
    !diagnostics

  let validate_operation store checker vocabulary facade_effect layers (layer : layer)
      (operation : operation) =
    let diagnostics = ref [] in
    let add values = diagnostics := !diagnostics @ values in
    List.iter
      (fun (label, claim) ->
        match identity_diagnostic label claim with None -> () | Some value -> add [ value ])
      [
        ("Call", operation.call);
        ("BoundPolicy", operation.bound_policy);
        ("assessment", operation.assessment);
        ("Proposal", operation.proposal.identity);
      ];
    add
      (check_pure_term checker ~result_type:vocabulary.result_type
         ~expected_result:vocabulary.governance_call
         ~expected_name:"GovernanceCall or Result _ GovernanceCall" ~allow_result:true
         operation.normalizer);
    add
      (check_pure_term checker ~result_type:vocabulary.result_type
         ~expected_result:vocabulary.outcome_summary ~expected_name:"GovernanceOutcomeSummary"
         ~allow_result:false operation.summarizer);
    if not (reachable_term_ref store ~start:operation.normalizer.hash ~target:vocabulary.make_call)
    then
      add
        [
          diagnostic operation.normalizer.meta "E1406"
            (operation.normalizer.label
           ^ " must reach the canonical governance.make-call constructor");
        ];
    if reachable_term_ref store ~start:operation.normalizer.hash ~target:vocabulary.debug_inspect
    then
      add
        [
          diagnostic operation.normalizer.meta "E1409"
            "call normalizers must not use generic debug.inspect";
        ];
    if reachable_term_ref store ~start:operation.summarizer.hash ~target:vocabulary.debug_inspect
    then
      add
        [
          diagnostic operation.summarizer.meta "E1409"
            "outcome summarizers must not use generic debug.inspect";
        ];
    let serialized =
      operation.serialized_call_data @ operation.proposal.serialized
      @ [
          operation.call.canonical_subject;
          operation.bound_policy.canonical_subject;
          operation.assessment.canonical_subject;
          operation.proposal.identity.canonical_subject;
        ]
    in
    if List.exists (form_contains_secret vocabulary.secret_constructor) serialized then
      add
        [
          diagnostic operation.meta "E1409"
            "governance review data may serialize SecretRef values but never an opaque Secret value";
        ];
    add (validate_action_shape facade_effect layer operation);
    add (validate_authorities vocabulary layers layer operation);
    add (validate_proposal operation);
    add (validate_flows vocabulary `Live operation.meta operation.live_flows);
    add (validate_lineage layers layer operation);
    !diagnostics

  let validate_sequence layers sequence =
    let base = validate_sequence sequence in
    if List.length sequence.layer_tokens = List.length layers then base
    else
      base
      @ [
          diagnostic sequence.meta "E1404"
            "the sequence token inventory must contain exactly one token use per membrane layer";
        ]

  let verify store (contract : contract) =
    let environment =
      match (resolve_vocabulary store contract.meta, make_checker store) with
      | Ok vocabulary, Ok checker -> Ok (vocabulary, checker)
      | Error diagnostic, Ok _ -> Error [ diagnostic ]
      | Ok _, Error diagnostics -> Error diagnostics
      | Error diagnostic, Error diagnostics -> Error (diagnostic :: diagnostics)
    in
    match environment with
    | Error diagnostics -> Error diagnostics
    | Ok (vocabulary, checker) -> (
        let diagnostics = ref [] in
        let add values = diagnostics := !diagnostics @ values in
        if not (String.equal contract.version version) then
          add
            [
              diagnostic contract.meta "E1400"
                (Printf.sprintf "unsupported governance verifier IR `%s`; expected `%s`"
                   contract.version version);
            ];
        add (validate_facade store contract);
        add (validate_topology contract);
        add (validate_sequence contract.layers contract.sequence);
        if List.exists (Hash.equal vocabulary.eval) contract.governed_reachable_effects then
          add
            [
              diagnostic contract.meta "E1412"
                "governed body reaches Eval, including effects discharged by an inner handler";
            ];
        List.iter
          (fun (layer : layer) ->
            List.iter
              (fun operation ->
                add
                  (validate_operation store checker vocabulary contract.facade_effect
                     contract.layers layer operation))
              layer.operations)
          contract.layers;
        match !diagnostics with
        | _ :: _ as diagnostics -> Error diagnostics
        | [] ->
            Ok
              {
                version = contract.version;
                facade_effect = contract.facade_effect;
                operations =
                  List.concat_map
                    (fun (layer : layer) ->
                      List.map
                        (fun (operation : operation) ->
                          {
                            layer_id = layer.layer_id;
                            operation_id = operation.operation_id;
                            authority = operation.frozen_authority;
                            call_id = operation.call.carried;
                            proposal_id = operation.proposal.identity.carried;
                          })
                        layer.operations)
                    contract.layers;
              })
end
