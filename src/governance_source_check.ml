(** See {!Governance_source_check}. *)

type identity = { name : string; hash : Hash.t; introduced_row : string list }

type operation = {
  name : string;
  hash : Hash.t;
  authority : string list;
  normalizer : Hash.t;
  summarizer : Hash.t;
}

type report = {
  facade : identity;
  live : identity;
  dry : identity;
  live_policy_binder : Hash.t;
  dry_policy_binder : Hash.t;
  layers : identity list;
  operations : operation list;
}

let version = "governance-check-v1"
let schema = "jacquard-governance-check-report-v1"
let profile = "workspace-v0"

let pinned name spelling =
  match Hash.of_canonical_hex spelling with
  | Some hash -> (name, hash)
  | None -> invalid_arg ("Bug_governance source checker has malformed pin for " ^ name)

let workspace =
  pinned "workspace" "d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0"

let read_file =
  pinned "workspace.read-file" "632071e3399c913a672c4bea7d4a8b394e64a9a517552eb296db824222fe2da1"

let write_file =
  pinned "workspace.write-file" "73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c"

let fetch =
  pinned "workspace.fetch" "f6536683575508ddcc2d5a6509df832e92897cbef2caf34219f993a110079b01"

let live =
  pinned "workspace.live" "804dfb7bc41dbdcd69e4ae88cb26254603f0c20e6788cc5965515dd51c2e82c6"

let dry =
  pinned "workspace.dry-run" "23f0c5350589521c4a7ac89f574911626335401ed1b1677c519b5c554cff5c1f"

let live_layer =
  pinned "workspace.live-layer" "8a6cf8b608942f610041d3218c29a87ebe3be2d0b862a673d4d193bb7616c7da"

let dry_layer =
  pinned "workspace.dry-layer" "ba50296ae4735b6c02ef92f04d24b770b7947d1d0524c27ead333d28a2236744"

let forward_layer =
  pinned "workspace.forward-layer"
    "41cd84e0b367b5978f1170ff7709514fe52555ffd23799c7b6d79262002e897c"

let with_sequence =
  pinned "governance.with-sequence"
    "fdef8b382618cf725a0059b16a5effc9a325eca507d2ba4acc53d5102f7f5d3e"

let eval_effect = pinned "eval" "94f82f3c17d019d6ca5092b24f19d51ad40720d0accbc4c50641ade0ca056c24"
let fs_effect = pinned "fs" "8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84"
let net_effect = pinned "net" "be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45"

let secret_effect =
  pinned "secret" "6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31"

let state_effect = pinned "state" "44a2946788e38fb6a734449880cce3d499aa5e2f876c5d9119773533b3d621a9"
let audit_effect = pinned "audit" "40bc4343fb2b4bcc18b18f63f7bb68675b746751bb40b876072e622046a81372"
let judge_effect = pinned "judge" "9b677b5e2c3ec8521c5d5dfac321ae361a959565e1cbf082fec4512199977354"

let governance_approval_effect =
  pinned "governance-approval-v1" "41b449689fb30e44180185007d845bbe246e5401fe3e8478f4fd02e556a3f2ed"

let live_policy_binder =
  pinned "governance.bind-live-policy"
    "755bd671a2a5651957aff7cf5e902a71fc01153e15ba374c40694f464f4079ff"

let dry_policy_binder =
  pinned "governance.bind-dry-policy"
    "6b7f57ef2002a375b55d4ea43a94f8f1a4d363456416b95e7c411b3c8e48122b"

let gate_live =
  pinned "governance.gate-live" "16503e4a588c7611487371fc49ee0e0ec7e3f809178ce30f2cab0162fea7ce8b"

let gate_dry =
  pinned "governance.gate-dry" "a87cd8a1b13312df7517f93d6caed82b801f7651ae482bf9566f2501863f5891"

let normalizers =
  [
    pinned "workspace.call-read" "e487b3e43c0408d30a42b7e67a7fdecbe596f9c361e78998992635435d4321f1";
    pinned "workspace.call-write" "224046671b81384fe5adfd663232f34c173c80b862d237c3351dec316e736ada";
    pinned "workspace.call-fetch" "318f57cd05bcf7e22859f25606fa221e5b3671a02c06b89774142d5ed7e4328b";
  ]

let summarizers =
  [
    pinned "workspace.summarize-read"
      "45035443af0182338269c3d359e4f8ed7e6f2d03ef99e9291b6db6e1838e66d2";
    pinned "workspace.summarize-write"
      "889f02313cbff80d7d1ad540954f8821929f5cf7921aa7d2732b78ea30bc21d4";
    pinned "workspace.summarize-fetch"
      "2f37080340bbe76a4b92d2ed47598bd635ab0a2a6870a4d1fb72caa87bb55850";
  ]

let drivers =
  [
    pinned "workspace.driver-read"
      "472d1fb519bff6cd000fe12f815c96186b90cb54b428ce175684840234b2ccaf";
    pinned "workspace.driver-write"
      "c25559992f4ed35eb5bdd244430124478fc554b2c8d75ac5d19230982dadeb88";
    pinned "workspace.driver-fetch"
      "f8587c5325ebfd2e4879a991cb78552b80182f907b89a42cdc912fe33be1c0c6";
  ]

let simulators =
  [
    pinned "workspace.read-simulation"
      "a809929d215e8168f0594df8f1b55045253a326e6df0ea31f1808451b7cdddd1";
    pinned "workspace.write-simulation"
      "6deb35abbf686d26671ceaa246b2f3292184133d4095e68798318c44d8cc0229";
    pinned "workspace.fetch-simulation"
      "baa040f255f9b6264047b53fa96cf48b84e216bf3b480e3c8bcb6eee0fcf1db4";
  ]

let debug_inspect =
  snd (pinned "debug.inspect" "5a620819e5f501da9a9959118176b547419c4bb0033d8b48ede4f9bd30cc2580")

let span_key diagnostic =
  match Diag.span diagnostic with
  | None -> ("", max_int, max_int, max_int)
  | Some span ->
      (span.Span.file, span.Span.start_pos.line, span.Span.start_pos.col, span.Span.start_pos.offset)

let sort_diagnostics diagnostics =
  List.sort
    (fun left right ->
      let location = compare (span_key left) (span_key right) in
      if location <> 0 then location
      else
        let code = String.compare (Diag.code_or_uncoded left) (Diag.code_or_uncoded right) in
        if code <> 0 then code
        else String.compare (Diag.to_cause_string left) (Diag.to_cause_string right))
    diagnostics

let diagnostic ?meta code cause =
  let meaning =
    match List.assoc_opt code Governance_verify.diagnostic_codes with
    | Some value -> String.capitalize_ascii value
    | None when String.equal code "E1413" -> "Canonical Workspace source contract is unavailable"
    | None -> "Governance source verification failed"
  in
  let next_step =
    match code with
    | "E1412" -> "Remove Eval entirely from the governed root and every source-owned dependency."
    | "E1407" ->
        "Route world actions through the canonical Workspace facade instead of raw effects."
    | "E1409" ->
        "Remove generic inspection and keep Secret values out of review or serialized data."
    | "E1408" ->
        "Keep Audit, GovernanceApprovalV1, Judge, and State behind the canonical governance gates."
    | "E1413" ->
        "Use a closed direct workspace.live or workspace.dry-run call, or an exact with-sequence, \
         live-layer, and forward-layer composition with distinct policy binders."
    | _ -> "Restore the canonical workspace-v0 artifact named by this diagnostic."
  in
  Diag.error ?span:(Option.bind meta Meta.span) ~domain:Governance ~code ~summary:meaning ~cause
    ~next_step ~contrast:None ()

let kind_name = function
  | Resolve.KTerm -> "term"
  | Resolve.KCon -> "constructor"
  | Resolve.KOp -> "operation"
  | Resolve.KType -> "type"
  | Resolve.KEffect -> "effect"

let require_pin store ~kind (name, expected) =
  match Store.lookup_kind store name kind with
  | Some entry when Hash.equal entry.Resolve.hash expected -> []
  | Some entry ->
      [
        diagnostic "E1400"
          (Printf.sprintf "canonical %s `%s` resolves to #%s instead of pinned #%s" (kind_name kind)
             name (Hash.to_hex entry.Resolve.hash) (Hash.to_hex expected));
      ]
  | None ->
      [
        diagnostic "E1400" (Printf.sprintf "canonical %s `%s` is unavailable" (kind_name kind) name);
      ]

let member_hashes declaration =
  match Canon.hash_decl declaration with Error _ -> [] | Ok hashes -> hashes.Canon.named

let refs_of_expr ?(group = []) expression =
  let rec visit refs (expression : Kernel.expr) =
    match expression.Kernel.it with
    | Kernel.Ref (hash, kind) -> (hash, kind, expression.Kernel.meta) :: refs
    | Kernel.GroupRef index -> (
        match List.nth_opt group index with
        | Some hash -> (hash, Kernel.Term, expression.Kernel.meta) :: refs
        | None -> refs)
    | Kernel.Lam (_, body) | Kernel.Ann (body, _) | Kernel.Unquote body -> visit refs body
    | Kernel.App (fn, arguments) -> List.fold_left visit (visit refs fn) arguments
    | Kernel.Let { value; body; _ } -> visit (visit refs value) body
    | Kernel.Match (subject, clauses) ->
        List.fold_left
          (fun refs clause -> visit refs clause.Kernel.cbody)
          (visit refs subject) clauses
    | Kernel.Tuple items -> List.fold_left visit refs items
    | Kernel.Handle { body; ret; ops } ->
        List.fold_left
          (fun refs clause ->
            let refs =
              match clause.Kernel.op with
              | Kernel.Hashed hash -> (hash, Kernel.Op, clause.Kernel.ometa) :: refs
              | Kernel.Named _ -> refs
            in
            visit refs clause.Kernel.obody)
          (visit (visit refs body) ret.Kernel.rbody)
          ops
    | Kernel.Quote form -> quote_refs refs form
    | Kernel.Lit _ | Kernel.Var _ -> refs
  and quote_refs ?(level = 0) refs (form : Form.t) =
    if String.equal form.Form.head "unquote" && level = 0 then
      match form.Form.args with
      | [ Form.F splice ] -> (
          match Kernel.expr_of_form splice with
          | Ok expression -> visit refs expression
          | Error _ -> refs)
      | _ -> refs
    else
      let level =
        match form.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
      in
      List.fold_left
        (fun refs -> function Form.F child -> quote_refs ~level refs child | _ -> refs)
        refs form.Form.args
  in
  List.rev (visit [] expression)

type source_member = { hash : Hash.t; body : Kernel.expr; group : Hash.t list }

let source_members declarations =
  List.concat_map
    (fun declaration ->
      match declaration.Kernel.it with
      | Kernel.DefTerm bindings ->
          let hashes = member_hashes declaration in
          let group = List.map snd hashes in
          List.filter_map
            (fun binding ->
              match List.assoc_opt binding.Kernel.bname hashes with
              | Some hash -> Some { hash; body = binding.Kernel.value; group }
              | None -> None)
            bindings
      | Kernel.DefType _ | Kernel.DefEffect _ -> [])
    declarations

let trusted_roots =
  [ snd live; snd dry; snd live_layer; snd dry_layer; snd forward_layer; snd with_sequence ]

let is_trusted_root hash = List.exists (Hash.equal hash) trusted_roots
let pvar pattern = match pattern.Kernel.it with Kernel.PVar name -> Some name | _ -> None
let var expression = match expression.Kernel.it with Kernel.Var name -> Some name | _ -> None

let ref_term expected expression =
  match expression.Kernel.it with
  | Kernel.Ref (actual, Kernel.Term) -> Hash.equal actual expected
  | _ -> false

let variables_equal expected expressions =
  List.length expected = List.length expressions
  && List.for_all2 (fun expected expression -> var expression = Some expected) expected expressions

type root_shape = Live_root | Dry_root | Forwarded_live_root of int

let classify_root (member : source_member) =
  match member.body.Kernel.it with
  | Kernel.Lam (parameters, body) -> (
      match List.filter_map pvar parameters with
      | names when List.length names = List.length parameters && List.length names >= 2 -> (
          let simulators = List.hd (List.rev names) in
          let policies = List.rev (List.tl (List.rev names)) in
          let distinct = List.sort_uniq String.compare names in
          if List.length distinct <> List.length names then None
          else
            let simple expected shape =
              match (policies, body.Kernel.it) with
              | [ policy ], Kernel.App (fn, [ policy_arg; simulators_arg; thunk ])
                when ref_term expected fn
                     && variables_equal [ policy; simulators ] [ policy_arg; simulators_arg ] -> (
                  match thunk.Kernel.it with Kernel.Lam ([], _) -> Some shape | _ -> None)
              | _ -> None
            in
            let rec forward_chain sequence simulators policies thunk =
              match (policies, thunk.Kernel.it) with
              | [], Kernel.Lam ([], _) -> true
              | policy :: rest, Kernel.Lam ([], application) -> (
                  match application.Kernel.it with
                  | Kernel.App (forward, [ sequence_arg; policy_arg; simulators_arg; next_thunk ])
                    when ref_term (snd forward_layer) forward
                         && variables_equal [ sequence; policy; simulators ]
                              [ sequence_arg; policy_arg; simulators_arg ] ->
                      forward_chain sequence simulators rest next_thunk
                  | _ -> false)
              | _ -> false
            in
            match simple (snd live) Live_root with
            | Some _ as result -> result
            | None -> (
                match simple (snd dry) Dry_root with
                | Some _ as result -> result
                | None -> (
                    match (policies, body.Kernel.it) with
                    | outer_policy :: forward_policies, Kernel.App (owner, [ owner_body ])
                      when forward_policies <> [] && ref_term (snd with_sequence) owner -> (
                        match owner_body.Kernel.it with
                        | Kernel.Lam ([ sequence_pattern ], live_application) -> (
                            match pvar sequence_pattern with
                            | None -> None
                            | Some sequence -> (
                                match live_application.Kernel.it with
                                | Kernel.App
                                    ( leaf,
                                      [ sequence_arg; policy_arg; simulators_arg; forward_thunk ] )
                                  when ref_term (snd live_layer) leaf
                                       && variables_equal
                                            [ sequence; outer_policy; simulators ]
                                            [ sequence_arg; policy_arg; simulators_arg ]
                                       && forward_chain sequence simulators forward_policies
                                            forward_thunk ->
                                    Some (Forwarded_live_root (List.length forward_policies))
                                | _ -> None))
                        | _ -> None)
                    | _ -> None)))
      | _ -> None)
  | _ -> None

let group_body store hash =
  match Store.locate_internal store hash with
  | Ok
      {
        Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ } as declaration;
        role = Store.Member index;
        _;
      } ->
      let group = member_hashes declaration |> List.map snd in
      List.nth_opt bindings index |> Option.map (fun binding -> (binding.Kernel.value, group))
  | Ok _ | Error _ -> None

let effect_of_operation store hash =
  match Store.locate_internal store hash with
  | Ok
      { Store.decl = { Kernel.it = Kernel.DefEffect _; _ }; decl_hash; role = Store.Operation _; _ }
    ->
      Some decl_hash
  | Ok _ | Error _ -> None

let validate_reachable store source root shape =
  let raw = [ snd fs_effect; snd net_effect; snd secret_effect ] in
  let control =
    [ snd audit_effect; snd governance_approval_effect; snd judge_effect; snd state_effect ]
  in
  let eval = snd eval_effect in
  let visited = ref [] in
  let diagnostics = ref [] in
  let expected_boundaries =
    ref
      (match shape with
      | Live_root -> [ (snd live, 1) ]
      | Dry_root -> [ (snd dry, 1) ]
      | Forwarded_live_root count ->
          [ (snd with_sequence, 1); (snd live_layer, 1); (snd forward_layer, count) ])
  in
  let consume_expected_boundary hash meta =
    match List.assoc_opt hash !expected_boundaries with
    | Some remaining when remaining > 0 ->
        expected_boundaries :=
          List.map
            (fun (expected, count) ->
              if Hash.equal expected hash then (expected, count - 1) else (expected, count))
            !expected_boundaries
    | Some _ | None ->
        diagnostics :=
          diagnostic ~meta "E1413"
            (Printf.sprintf
               "governed source reaches an additional trusted membrane boundary #%s outside the \
                exact root topology"
               (Hash.to_hex hash))
          :: !diagnostics
  in
  let rec visit hash kind meta =
    if kind = Kernel.Op then
      match effect_of_operation store hash with
      | Some operation_effect ->
          if Hash.equal operation_effect eval then
            diagnostics :=
              diagnostic ~meta "E1412"
                "Eval is reachable from the governed source, including beneath a local handler"
              :: !diagnostics
          else if List.exists (Hash.equal operation_effect) raw then
            diagnostics :=
              diagnostic ~meta "E1407"
                (Printf.sprintf
                   "governed source reaches raw world effect #%s outside a trusted Workspace \
                    boundary"
                   (Hash.to_hex operation_effect))
              :: !diagnostics
          else if List.exists (Hash.equal operation_effect) control then
            diagnostics :=
              diagnostic ~meta "E1408"
                (Printf.sprintf
                   "governed source reaches gate-owned control effect #%s outside a trusted \
                    governance boundary"
                   (Hash.to_hex operation_effect))
              :: !diagnostics
      | None -> ()
    else if kind = Kernel.Term && is_trusted_root hash then consume_expected_boundary hash meta
    else if kind = Kernel.Term && Hash.equal hash debug_inspect then
      diagnostics :=
        diagnostic ~meta "E1409" "governed source reaches generic debug.inspect" :: !diagnostics
    else if kind = Kernel.Term && not (List.exists (Hash.equal hash) !visited) then begin
      visited := hash :: !visited;
      let body =
        match List.find_opt (fun member -> Hash.equal member.hash hash) source with
        | Some member -> Some (member.body, member.group)
        | None -> group_body store hash
      in
      Option.iter
        (fun (body, group) -> List.iter (fun (h, k, m) -> visit h k m) (refs_of_expr ~group body))
        body
    end
  in
  List.iter
    (fun (hash, kind, meta) -> visit hash kind meta)
    (refs_of_expr ~group:root.group root.body);
  List.rev !diagnostics

let rec has_only_closed_rows ty =
  match Types.repr ty with
  | Types.TCon (_, arguments) | Types.TTuple arguments ->
      List.for_all has_only_closed_rows arguments
  | Types.TArrow (parameters, row, result) ->
      (Types.repr_row row).Types.tail = Types.RClosed
      && List.for_all has_only_closed_rows parameters
      && has_only_closed_rows result
  | Types.TResume (parameter, row, result) | Types.TVariadicArrow (parameter, row, result) ->
      (Types.repr_row row).Types.tail = Types.RClosed
      && has_only_closed_rows parameter && has_only_closed_rows result
  | Types.TVar _ | Types.TSkolem _ -> true

let expected_root_effects = function
  | Live_root | Forwarded_live_root _ ->
      [
        snd audit_effect;
        snd governance_approval_effect;
        snd secret_effect;
        snd fs_effect;
        snd judge_effect;
        snd net_effect;
      ]
  | Dry_root -> [ snd audit_effect; snd judge_effect ]

let validate_root_shape checker root shape =
  match Check.force_term checker root.hash with
  | Error diagnostics -> diagnostics
  | Ok scheme when has_only_closed_rows scheme.Types.ty -> (
      match Types.repr scheme.Types.ty with
      | Types.TArrow (_, row, _) ->
          let actual = (Types.repr_row row).Types.effects in
          let expected = List.sort_uniq Hash.compare (expected_root_effects shape) in
          if actual = expected then []
          else
            [
              diagnostic "E1413"
                (Printf.sprintf
                   "workspace-v0 governed root has outward effect row {%s}; the fixed report can \
                    make no truthful claim unless it is exactly {%s}"
                   (Check.show_row checker row)
                   (Check.show_row checker (Types.closed_row expected)));
            ]
      | _ ->
          [
            diagnostic "E1413" "workspace-v0 governed root does not have the required callable type";
          ])
  | Ok _ ->
      [
        diagnostic "E1413"
          "workspace-v0 governed root has an open effect-row tail, so reachable Eval cannot be \
           excluded";
      ]

let validate_schemes checker =
  let expected =
    [
      ( live,
        "forall a | e. (BoundPolicy LivePolicy, WorkspaceSimulators, () ->{Workspace | e} a) \
         ->{Audit, GovernanceApprovalV1, Secret, Fs, Judge, Net | e} a" );
      ( dry,
        "forall a | e. (BoundPolicy DryPolicy, WorkspaceSimulators, () ->{Workspace | e} a) \
         ->{Audit, Judge | e} a" );
      ( forward_layer,
        "forall a | e. (AuditSequence, BoundPolicy LivePolicy, WorkspaceSimulators, () \
         ->{Workspace | e} a) ->{Audit, GovernanceApprovalV1, State, Judge, Workspace | e} a" );
    ]
  in
  List.filter_map
    (fun ((name, hash), expected) ->
      match Check.force_term checker hash with
      | Error diagnostics ->
          Some
            (diagnostic "E1405"
               (Printf.sprintf "%s cannot be checked: %s" name
                  (String.concat "; " (List.map Diag.to_cause_string diagnostics))))
      | Ok scheme ->
          let actual = Check.show_scheme checker scheme in
          if String.equal actual expected then None
          else
            Some (diagnostic "E1405" (Printf.sprintf "%s has noncanonical scheme %s" name actual)))
    expected

let verify store checker declarations =
  let environment_pins =
    [
      (Resolve.KEffect, workspace);
      (Resolve.KOp, read_file);
      (Resolve.KOp, write_file);
      (Resolve.KOp, fetch);
      (Resolve.KTerm, live);
      (Resolve.KTerm, dry);
      (Resolve.KTerm, live_layer);
      (Resolve.KTerm, dry_layer);
      (Resolve.KTerm, forward_layer);
      (Resolve.KTerm, with_sequence);
      (Resolve.KTerm, live_policy_binder);
      (Resolve.KTerm, dry_policy_binder);
      (Resolve.KTerm, gate_live);
      (Resolve.KTerm, gate_dry);
      (Resolve.KEffect, eval_effect);
      (Resolve.KEffect, fs_effect);
      (Resolve.KEffect, net_effect);
      (Resolve.KEffect, secret_effect);
      (Resolve.KEffect, state_effect);
      (Resolve.KEffect, audit_effect);
      (Resolve.KEffect, judge_effect);
      (Resolve.KEffect, governance_approval_effect);
      (Resolve.KTerm, ("debug.inspect", debug_inspect));
    ]
    @ List.map
        (fun value -> (Resolve.KTerm, value))
        (normalizers @ summarizers @ drivers @ simulators)
  in
  let diagnostics =
    List.concat_map (fun (kind, pin) -> require_pin store ~kind pin) environment_pins
    @ validate_schemes checker
  in
  let members = source_members declarations in
  let roots =
    List.filter_map
      (fun member -> Option.map (fun shape -> (member, shape)) (classify_root member))
      members
  in
  let diagnostics =
    match roots with
    | [ (root, shape) ] ->
        diagnostics
        @ validate_root_shape checker root shape
        @ validate_reachable store members root shape
    | [] ->
        diagnostics
        @ [
            diagnostic "E1413"
              "no complete canonical workspace-v0 source root was found in the declaration-only \
               input";
          ]
    | roots ->
        diagnostics
        @ [
            diagnostic "E1413"
              (Printf.sprintf
                 "workspace-v0 source root is ambiguous: %d declarations reach a canonical boundary"
                 (List.length roots));
          ]
  in
  match sort_diagnostics diagnostics with
  | _ :: _ as diagnostics -> Error diagnostics
  | [] ->
      let operation name_hash authority normalizer summarizer =
        {
          name = fst name_hash;
          hash = snd name_hash;
          authority;
          normalizer = snd normalizer;
          summarizer = snd summarizer;
        }
      in
      let layers =
        match roots with
        | [ (_, Forwarded_live_root count) ] ->
            List.init count (fun _ ->
                {
                  name = fst forward_layer;
                  hash = snd forward_layer;
                  introduced_row =
                    [ "Audit"; "GovernanceApprovalV1"; "State"; "Judge"; "Workspace" ];
                })
            @ [
                {
                  name = fst live_layer;
                  hash = snd live_layer;
                  introduced_row =
                    [ "Audit"; "GovernanceApprovalV1"; "State"; "Secret"; "Fs"; "Judge"; "Net" ];
                };
              ]
        | _ -> []
      in
      Ok
        {
          facade = { name = "Workspace"; hash = snd workspace; introduced_row = [ "Workspace" ] };
          live =
            {
              name = fst live;
              hash = snd live;
              introduced_row = [ "Audit"; "GovernanceApprovalV1"; "Secret"; "Fs"; "Judge"; "Net" ];
            };
          dry = { name = fst dry; hash = snd dry; introduced_row = [ "Audit"; "Judge" ] };
          live_policy_binder = snd live_policy_binder;
          dry_policy_binder = snd dry_policy_binder;
          layers;
          operations =
            [
              operation read_file [ "Fs" ] (List.nth normalizers 0) (List.nth summarizers 0);
              operation write_file [ "Fs" ] (List.nth normalizers 1) (List.nth summarizers 1);
              operation fetch [ "Net"; "Secret" ] (List.nth normalizers 2) (List.nth summarizers 2);
            ];
        }

let show_row values = "{" ^ String.concat ", " values ^ "}"
let show_authority values = "[" ^ String.concat ", " values ^ "]"
let hex hash = "#" ^ Hash.to_hex hash

let render_text report =
  let buffer = Buffer.create 1024 in
  let line format =
    Printf.ksprintf
      (fun value ->
        Buffer.add_string buffer value;
        Buffer.add_char buffer '\n')
      format
  in
  line "ok %s profile=%s" version profile;
  line "facade %s %s introduced-row=%s" report.facade.name (hex report.facade.hash)
    (show_row report.facade.introduced_row);
  line "live %s %s introduced-row=%s" report.live.name (hex report.live.hash)
    (show_row report.live.introduced_row);
  line "dry %s %s introduced-row=%s" report.dry.name (hex report.dry.hash)
    (show_row report.dry.introduced_row);
  line "policy-binders live=%s dry=%s" (hex report.live_policy_binder)
    (hex report.dry_policy_binder);
  List.iter
    (fun (layer : identity) ->
      line "layer %s %s introduced-row=%s" layer.name (hex layer.hash)
        (show_row layer.introduced_row))
    report.layers;
  List.iter
    (fun operation ->
      line "operation %s %s authority=%s normalizer=%s summarizer=%s" operation.name
        (hex operation.hash)
        (show_authority operation.authority)
        (hex operation.normalizer) (hex operation.summarizer))
    report.operations;
  line "runtime-identities dynamic verify-with=\"jac governance verify-run BUNDLE\"";
  Buffer.contents buffer

let identity_json (identity : identity) =
  `Assoc
    [
      ("name", `String identity.name);
      ("identity", `String (Hash.to_hex identity.hash));
      ("introduced_row", `List (List.map (fun value -> `String value) identity.introduced_row));
    ]

let render_json_v1 report =
  let operation_json operation =
    `Assoc
      [
        ("name", `String operation.name);
        ("identity", `String (Hash.to_hex operation.hash));
        ("authority", `List (List.map (fun value -> `String value) operation.authority));
        ("normalizer", `String (Hash.to_hex operation.normalizer));
        ("summarizer", `String (Hash.to_hex operation.summarizer));
      ]
  in
  Yojson.Safe.to_string
    (`Assoc
       [
         ("schema", `String schema);
         ("profile", `String profile);
         ("facade", identity_json report.facade);
         ("live", identity_json report.live);
         ("dry", identity_json report.dry);
         ( "policy_binders",
           `Assoc
             [
               ("live", `String (Hash.to_hex report.live_policy_binder));
               ("dry", `String (Hash.to_hex report.dry_policy_binder));
             ] );
         ("layers", `List (List.map identity_json report.layers));
         ("operations", `List (List.map operation_json report.operations));
         ( "runtime_identities",
           `Assoc
             [
               ("status", `String "dynamic");
               ("verification_command", `String "jac governance verify-run BUNDLE");
             ] );
       ])
