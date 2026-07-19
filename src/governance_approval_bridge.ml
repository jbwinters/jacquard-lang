(** Narrow trusted driver for a single queue-backed GovernanceApprovalV1 rendezvous. *)

type outcome =
  | Completed of Value.t
  | Awaiting_approval of { proposal_id : Hash.t; queue_head : Hash.t }
  | Busy of { proposal_id : Hash.t }
  | Stale_approval of { proposal_id : Hash.t }

let ( let* ) = Result.bind

exception Bug_invalid_governance_approval_bridge_hash of string

let diagnostic ?code ~summary ~cause ~next_step () =
  Diag.error ?code ~domain:Governance ~summary ~cause ~next_step ~contrast:None ()

let invalid_proposal cause =
  Error
    [
      diagnostic ~code:"E1523"
        ~summary:"A GovernanceProposal or queue approver configuration is invalid." ~cause
        ~next_step:
          "Use the exact released GovernanceProposal runtime carrier and trusted sorted unique \
           approver configuration."
        ();
    ]

let invalid_decision cause =
  Error
    [
      diagnostic ~code:"E1524" ~summary:"An approval Decision or authenticated actor is invalid."
        ~cause ~next_step:"Restore the exact released Decision carrier bound to this proposal." ();
    ]

let bridge_refusal cause =
  Error
    [
      diagnostic ~code:"E1527" ~summary:"The queue-backed approval bridge refused the workflow."
        ~cause
        ~next_step:
          "Run exactly one queue-backed approval rendezvous per invocation and handle other \
           effects through explicit root grants."
        ();
    ]

let runtime_error error = Error [ Runtime_err.to_diag error ]
let form head children = Form.form head (List.map (fun child -> Form.F child) children)
let hash_form value = Form.form "hash" [ Form.Hash value ]
let text_form value = Form.form "lit" [ Form.Text value ]

type schema = {
  ask : Hash.t;
  proposal : Hash.t;
  version : Hash.t;
  nil : Hash.t;
  cons : Hash.t;
  effect_authority : Hash.t;
  resource : Hash.t;
  none : Hash.t;
  some : Hash.t;
  outcome : Hash.t;
  approved : Hash.t;
  denied : Hash.t;
  escalate : Hash.t;
}

type identity = {
  name : string;
  kind : Resolve.nkind;
  hash : Hash.t;
  owner : Hash.t;
  role : Store.role;
}

let frozen_hash label encoded =
  match Hash.of_canonical_hex encoded with
  | Some hash -> hash
  | None ->
      raise
        (Bug_invalid_governance_approval_bridge_hash
           (Printf.sprintf "malformed frozen %s hash" label))

let identity name kind hash owner role =
  { name; kind; hash = frozen_hash name hash; owner = frozen_hash (name ^ " owner") owner; role }

let approval_effect =
  identity "governance-approval-v1" Resolve.KEffect
    "41b449689fb30e44180185007d845bbe246e5401fe3e8478f4fd02e556a3f2ed"
    "41b449689fb30e44180185007d845bbe246e5401fe3e8478f4fd02e556a3f2ed" Store.Whole

let approval_ask =
  identity "governance-approval.ask" Resolve.KOp
    "582ff208063ca627586a2fdde5daeeb6a50ca89e69edd2abc9e00fb1cb010f3e"
    "41b449689fb30e44180185007d845bbe246e5401fe3e8478f4fd02e556a3f2ed" (Store.Operation 0)

let proposal_type =
  identity "governance-proposal" Resolve.KType
    "c3acd6332f0fdb23bcc800edd64a11192d2744cc824447fbbd7c8d6069f487b8"
    "c3acd6332f0fdb23bcc800edd64a11192d2744cc824447fbbd7c8d6069f487b8" Store.Whole

let proposal_constructor =
  identity "governance-proposal-v0" Resolve.KCon
    "9763635de4164bff9ee5776f508c9c8e6fc557016b0b74d72ded8b5e2ecacfb9"
    "c3acd6332f0fdb23bcc800edd64a11192d2744cc824447fbbd7c8d6069f487b8" (Store.Constructor 0)

let version_type =
  identity "governance-version" Resolve.KType
    "d0de794881ae274694643bb9d87eb8e8c0faa81131a409042141c9f7acb8dabd"
    "d0de794881ae274694643bb9d87eb8e8c0faa81131a409042141c9f7acb8dabd" Store.Whole

let version_constructor =
  identity "governance-v0" Resolve.KCon
    "c59ab04f481efce20a50b966fd5c652e3387a24a947b1c2280592d8e4b425cb9"
    "d0de794881ae274694643bb9d87eb8e8c0faa81131a409042141c9f7acb8dabd" (Store.Constructor 0)

let list_type =
  identity "list" Resolve.KType "03b4cd180ed05bf70d8a3e401dfea0688a46cf6b8c6469fd8e7e013c9e603c81"
    "03b4cd180ed05bf70d8a3e401dfea0688a46cf6b8c6469fd8e7e013c9e603c81" Store.Whole

let nil_constructor =
  identity "nil" Resolve.KCon "a3213f58f1ac022ec4bc77f4b50465e29552fc2badb73c62df89f1e9fe57e382"
    "03b4cd180ed05bf70d8a3e401dfea0688a46cf6b8c6469fd8e7e013c9e603c81" (Store.Constructor 0)

let cons_constructor =
  identity "cons" Resolve.KCon "e085c120bdafd78f89fc8ec87b699ce57c93e93145d70387d55097390e8f5752"
    "03b4cd180ed05bf70d8a3e401dfea0688a46cf6b8c6469fd8e7e013c9e603c81" (Store.Constructor 1)

let authority_type =
  identity "governance-authority" Resolve.KType
    "e9588d64ca8ad158e1057c80a6e4e4303823f14c3a896541fcb58706e12ca2ae"
    "e9588d64ca8ad158e1057c80a6e4e4303823f14c3a896541fcb58706e12ca2ae" Store.Whole

let effect_constructor =
  identity "governance-effect" Resolve.KCon
    "71118bba88676ae86ef8fa3bf4ce35cc8d0d0b52ef7f29a46486a9dc028487a8"
    "e9588d64ca8ad158e1057c80a6e4e4303823f14c3a896541fcb58706e12ca2ae" (Store.Constructor 0)

let resource_constructor =
  identity "governance-resource" Resolve.KCon
    "9b1e62bc7c5b6d81067e2ff34604c221c73c239866c48316fa607c113023bb12"
    "e9588d64ca8ad158e1057c80a6e4e4303823f14c3a896541fcb58706e12ca2ae" (Store.Constructor 1)

let option_type =
  identity "option" Resolve.KType "dd204741db0b2a42c765bd302ee3ec2cc61ef8471e6e8ca1194321d8c757e1ad"
    "dd204741db0b2a42c765bd302ee3ec2cc61ef8471e6e8ca1194321d8c757e1ad" Store.Whole

let none_constructor =
  identity "none" Resolve.KCon "52c6f25ee495df78e956e4f9c3d48be0048980ab6f640e31e185041829b3568d"
    "dd204741db0b2a42c765bd302ee3ec2cc61ef8471e6e8ca1194321d8c757e1ad" (Store.Constructor 0)

let some_constructor =
  identity "some" Resolve.KCon "2c27a9b58e0a831959c7cb7fcd0bd2af5d4af2aefbf1ee84e7c26679c5721a71"
    "dd204741db0b2a42c765bd302ee3ec2cc61ef8471e6e8ca1194321d8c757e1ad" (Store.Constructor 1)

let outcome_type =
  identity "governance-outcome-summary" Resolve.KType
    "7a564b18a2535d29933ec1db4003776b9b9db65130d4dd4dc31c7db88f064aee"
    "7a564b18a2535d29933ec1db4003776b9b9db65130d4dd4dc31c7db88f064aee" Store.Whole

let outcome_constructor =
  identity "governance-outcome-summary-v0" Resolve.KCon
    "4a6d6e9345cd6cf77b97fa0bec0991927a18de26dae72646cde8e5cba5b2abad"
    "7a564b18a2535d29933ec1db4003776b9b9db65130d4dd4dc31c7db88f064aee" (Store.Constructor 0)

let decision_type =
  identity "decision" Resolve.KType
    "4d07b0003ce00355c129e894d589c0626bc7ccb3230305537c908a37d5012e4c"
    "4d07b0003ce00355c129e894d589c0626bc7ccb3230305537c908a37d5012e4c" Store.Whole

let approved_constructor =
  identity "approved" Resolve.KCon
    "5fd7cbc33194f5d2d1d1f7b6253f237b8144d52040a0612aff416b99a8e768fa"
    "4d07b0003ce00355c129e894d589c0626bc7ccb3230305537c908a37d5012e4c" (Store.Constructor 0)

let denied_constructor =
  identity "denied" Resolve.KCon "5b75b676f39f132d7501b1898270bd1a2e3bc8b778768a4a92540344c63357ef"
    "4d07b0003ce00355c129e894d589c0626bc7ccb3230305537c908a37d5012e4c" (Store.Constructor 1)

let escalate_constructor =
  identity "escalate" Resolve.KCon
    "fff9104f263945797dd2a4ae868b668f9327eeafedebe4d0c894d29700327ee1"
    "4d07b0003ce00355c129e894d589c0626bc7ccb3230305537c908a37d5012e4c" (Store.Constructor 2)

let identities =
  [
    approval_effect;
    approval_ask;
    proposal_type;
    proposal_constructor;
    version_type;
    version_constructor;
    list_type;
    nil_constructor;
    cons_constructor;
    authority_type;
    effect_constructor;
    resource_constructor;
    option_type;
    none_constructor;
    some_constructor;
    outcome_type;
    outcome_constructor;
    decision_type;
    approved_constructor;
    denied_constructor;
    escalate_constructor;
  ]

let role_equal expected actual =
  match (expected, actual) with
  | Store.Whole, Store.Whole -> true
  | Store.Member left, Store.Member right
  | Store.Constructor left, Store.Constructor right
  | Store.Operation left, Store.Operation right ->
      left = right
  | _ -> false

let require_identity store identity =
  match Store.lookup_kind store identity.name identity.kind with
  | None -> bridge_refusal (Printf.sprintf "required released name `%s` is not bound" identity.name)
  | Some entry when not (Hash.equal entry.Resolve.hash identity.hash) ->
      bridge_refusal
        (Printf.sprintf "released name `%s` is rebound to #%s instead of frozen #%s" identity.name
           (Hash.to_hex entry.Resolve.hash) (Hash.to_hex identity.hash))
  | Some _ -> (
      match Store.locate store identity.hash with
      | Ok located
        when Hash.equal located.Store.decl_hash identity.owner
             && role_equal identity.role located.Store.role ->
          Ok ()
      | Ok located ->
          bridge_refusal
            (Printf.sprintf "released name `%s` has owner #%s or member role inconsistent with #%s"
               identity.name
               (Hash.to_hex located.Store.decl_hash)
               (Hash.to_hex identity.owner))
      | Error _ ->
          bridge_refusal
            (Printf.sprintf "frozen identity #%s for `%s` is absent from the loaded Store"
               (Hash.to_hex identity.hash) identity.name))

let load_schema store =
  let* () =
    List.fold_left
      (fun checked identity ->
        let* () = checked in
        require_identity store identity)
      (Ok ()) identities
  in
  Ok
    {
      ask = approval_ask.hash;
      proposal = proposal_constructor.hash;
      version = version_constructor.hash;
      nil = nil_constructor.hash;
      cons = cons_constructor.hash;
      effect_authority = effect_constructor.hash;
      resource = resource_constructor.hash;
      none = none_constructor.hash;
      some = some_constructor.hash;
      outcome = outcome_constructor.hash;
      approved = approved_constructor.hash;
      denied = denied_constructor.hash;
      escalate = escalate_constructor.hash;
    }

let exact_constructor expected = function
  | Value.VCon { con; args; _ } when Hash.equal con expected -> Some args
  | _ -> None

let encode_version schema value =
  match exact_constructor schema.version value with
  | Some [] -> Ok (form "governance-v0" [])
  | _ -> invalid_proposal "GovernanceProposal has an invalid GovernanceVersion runtime value"

let encode_outcome schema value =
  match exact_constructor schema.outcome value with
  | Some [ version; Value.VText status; Value.VHash digest; Value.VText detail ] ->
      let* version = encode_version schema version in
      Ok
        (form "governance-outcome-summary-v0"
           [ version; text_form status; hash_form digest; text_form detail ])
  | _ -> invalid_proposal "GovernanceProposal preview has an invalid outcome runtime value"

let encode_preview schema value =
  match exact_constructor schema.none value with
  | Some [] -> Ok (form "none-v0" [])
  | _ -> (
      match exact_constructor schema.some value with
      | Some [ outcome ] ->
          let* outcome = encode_outcome schema outcome in
          Ok (form "some-v0" [ outcome ])
      | _ -> invalid_proposal "GovernanceProposal has an invalid preview runtime value")

let encode_authority schema value =
  match exact_constructor schema.effect_authority value with
  | Some [ Value.VHash authority_hash ] ->
      Ok (form "governance-effect-v0" [ hash_form authority_hash ])
  | _ -> (
      match exact_constructor schema.resource value with
      | Some [ Value.VHash authority_hash; Value.VText scope; Value.VHash configuration ] ->
          Ok
            (form "governance-resource-v0"
               [ hash_form authority_hash; text_form scope; hash_form configuration ])
      | _ -> invalid_proposal "GovernanceProposal has an invalid authority runtime value")

let encode_authorities schema value =
  let rec loop reversed value =
    match exact_constructor schema.nil value with
    | Some [] -> Ok (form "governance-authority-list-v0" (List.rev reversed))
    | _ -> (
        match exact_constructor schema.cons value with
        | Some [ authority; rest ] ->
            let* authority = encode_authority schema authority in
            loop (authority :: reversed) rest
        | _ -> invalid_proposal "GovernanceProposal authority is not an exact List runtime value")
  in
  loop [] value

let encode_proposal schema value =
  match exact_constructor schema.proposal value with
  | Some
      [
        version;
        Value.VHash carried;
        Value.VHash call;
        Value.VHash policy;
        Value.VHash assessment;
        Value.VCode rendering;
        Value.VText summary;
        authorities;
        preview;
      ] ->
      let* version = encode_version schema version in
      let* authorities = encode_authorities schema authorities in
      let* preview = encode_preview schema preview in
      let subject =
        form "governance-proposal-v0"
          [
            version;
            hash_form call;
            hash_form policy;
            hash_form assessment;
            authorities;
            preview;
            rendering;
            text_form summary;
          ]
      in
      let* computed = Governance_approval_queue.proposal_id subject in
      if Hash.equal carried computed then Ok (computed, subject)
      else invalid_proposal "carried proposal ID does not match exact governance-proposal-v0 Code"
  | _ -> invalid_proposal "approval operation argument is not the exact GovernanceProposal carrier"

let decision_value schema = function
  | { Form.head = "approved-v1"; args = [ Form.F proposal; Form.F approver; Form.F evidence ]; _ }
    -> (
      match (proposal, approver) with
      | ( { Form.head = "hash"; args = [ Form.Hash proposal ]; _ },
          { Form.head = "lit"; args = [ Form.Text approver ]; _ } ) ->
          Ok
            (Value.VCon
               {
                 con = schema.approved;
                 name = "approved";
                 args = [ Value.VHash proposal; Value.VText approver; Value.VCode evidence ];
               })
      | _ -> invalid_decision "Delivered Approved fields are malformed")
  | { Form.head = "denied-v1"; args = [ Form.F proposal; Form.F approver; Form.F reason ]; _ } -> (
      match (proposal, approver, reason) with
      | ( { Form.head = "hash"; args = [ Form.Hash proposal ]; _ },
          { Form.head = "lit"; args = [ Form.Text approver ]; _ },
          { Form.head = "lit"; args = [ Form.Text reason ]; _ } ) ->
          Ok
            (Value.VCon
               {
                 con = schema.denied;
                 name = "denied";
                 args = [ Value.VHash proposal; Value.VText approver; Value.VText reason ];
               })
      | _ -> invalid_decision "Delivered Denied fields are malformed")
  | { Form.head = "escalate-v1"; args = [ Form.F proposal; Form.F reason ]; _ } -> (
      match (proposal, reason) with
      | ( { Form.head = "hash"; args = [ Form.Hash proposal ]; _ },
          { Form.head = "lit"; args = [ Form.Text reason ]; _ } ) ->
          Ok
            (Value.VCon
               {
                 con = schema.escalate;
                 name = "escalate";
                 args = [ Value.VHash proposal; Value.VText reason ];
               })
      | _ -> invalid_decision "Delivered Escalate fields are malformed")
  | { Form.head; _ } ->
      invalid_decision (Printf.sprintf "Delivered Decision uses unsupported carrier `%s`" head)

let run ctx ~file ~allowed_approvers initial =
  let* schema = load_schema (Eval.store ctx) in
  let rec drive approval_resumed state =
    match Eval.run_state_capturing_once_routed ctx state with
    | Error error -> runtime_error error
    | Ok (Eval.OCValue value) -> Ok (Completed value)
    | Ok (Eval.OCOp { op; name = _; args; resume }) when Hash.equal op schema.ask -> (
        if approval_resumed then
          bridge_refusal
            "a second sequential governance-approval.ask reached the single-rendezvous driver"
        else
          let* proposal_id, proposal =
            match args with
            | [ proposal ] -> encode_proposal schema proposal
            | _ -> invalid_proposal "governance-approval.ask did not receive exactly one argument"
          in
          let* submitted =
            Governance_approval_queue.submit_file ~file ~proposal_id ~proposal ~allowed_approvers
          in
          match submitted with
          | Governance_approval_queue.Busy -> Ok (Busy { proposal_id })
          | Governance_approval_queue.Stale -> Ok (Stale_approval { proposal_id })
          | Governance_approval_queue.Applied queue_head ->
              Ok (Awaiting_approval { proposal_id; queue_head })
          | Governance_approval_queue.Unchanged queue_head -> (
              let* delivery = Governance_approval_queue.consume_file ~file ~proposal_id in
              match delivery with
              | Governance_approval_queue.Pending_delivery ->
                  Ok (Awaiting_approval { proposal_id; queue_head })
              | Governance_approval_queue.Busy_delivery -> Ok (Busy { proposal_id })
              | Governance_approval_queue.Stale_delivery -> Ok (Stale_approval { proposal_id })
              | Governance_approval_queue.Delivered { decision; _ } ->
                  let* decision = decision_value schema decision in
                  drive true (Eval.apply_state ctx resume [ decision ])))
    | Ok (Eval.OCOp { op; name; args; resume }) -> (
        match Eval.dispatch_root_operation ctx ~resume ~op ~name ~effect_:"" args with
        | Error error -> runtime_error error
        | Ok value -> drive approval_resumed (Eval.apply_state ctx resume [ value ]))
  in
  drive false initial
