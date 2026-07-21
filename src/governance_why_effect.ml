(** See {!Governance_why_effect}. *)

type identity = { name : string; hash : Hash.t }

type chain = {
  source_path : identity list;
  operation : identity;
  forwarding_layers : identity list;
  live_leaf : identity;
  driver : identity;
  raw_effect : identity;
}

type operation_fact = {
  operation : identity;
  raw_authority : identity list;
  normalizer : identity;
  summarizer : identity;
  simulator : identity;
  driver : identity;
  driver_introduced_raw_row : identity list;
}

type report = {
  requested_effect : identity;
  source_root : identity;
  topology : string;
  facade : identity;
  facade_operations : identity list;
  reached_operations : operation_fact list;
  chains : chain list;
}

let schema = "jacquard-why-effect-report-v1"
let facts_schema = "jacquard-governance-review-facts-v1"

let pinned name spelling =
  match Hash.of_canonical_hex spelling with
  | Some hash -> { name; hash }
  | None -> invalid_arg ("Bug_governance_why_effect malformed pin: " ^ name)

let workspace =
  pinned "Workspace" "d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0"

let read_file =
  pinned "workspace.read-file" "632071e3399c913a672c4bea7d4a8b394e64a9a517552eb296db824222fe2da1"

let write_file =
  pinned "workspace.write-file" "73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c"

let fetch =
  pinned "workspace.fetch" "f6536683575508ddcc2d5a6509df832e92897cbef2caf34219f993a110079b01"

let live =
  pinned "workspace.live" "804dfb7bc41dbdcd69e4ae88cb26254603f0c20e6788cc5965515dd51c2e82c6"

let live_layer =
  pinned "workspace.live-layer" "8a6cf8b608942f610041d3218c29a87ebe3be2d0b862a673d4d193bb7616c7da"

let forward_layer =
  pinned "workspace.forward-layer"
    "41cd84e0b367b5978f1170ff7709514fe52555ffd23799c7b6d79262002e897c"

let fs = pinned "Fs" "8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84"
let net = pinned "Net" "be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45"
let secret = pinned "Secret" "6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31"

let simulators =
  [
    pinned "workspace.read-simulation"
      "a809929d215e8168f0594df8f1b55045253a326e6df0ea31f1808451b7cdddd1";
    pinned "workspace.write-simulation"
      "6deb35abbf686d26671ceaa246b2f3292184133d4095e68798318c44d8cc0229";
    pinned "workspace.fetch-simulation"
      "baa040f255f9b6264047b53fa96cf48b84e216bf3b480e3c8bcb6eee0fcf1db4";
  ]

let diagnostic ?span code cause =
  let summary, next_step =
    match code with
    | "E1534" ->
        ( "The requested effect is not supported by why-effect.",
          "Use Fs, Net, Secret, or the exact released identity for one of those effects." )
    | "E1535" ->
        ( "A reachable callable cannot be attributed safely.",
          "Make the call target an exact source-owned term, GroupRef, direct lambda, constructor, \
           or Workspace operation." )
    | "E1536" ->
        ( "A reachable local handler invalidates Workspace attribution.",
          "Remove the local Workspace or requested raw-effect handler from the verified payload \
           path." )
    | "E1537" ->
        ( "A reachable source reference or splice is malformed.",
          "Repair the GroupRef or live unquote so its exact source expression can be analyzed." )
    | "E1538" ->
        ( "The why-effect traversal budget was exhausted.",
          "Reduce the reachable source graph before requesting effect attribution." )
    | _ -> raise (Diag.Bug_invalid_diagnostic ("unknown why-effect diagnostic " ^ code))
  in
  Diag.error ?span ~domain:Governance ~code ~summary ~cause ~next_step ~contrast:None ()

let sort_diagnostics = Governance_source_check.sort_diagnostics

let requested_effect value =
  let candidates = [ fs; net; secret ] in
  match List.find_opt (fun candidate -> String.equal value candidate.name) candidates with
  | Some candidate -> Ok candidate
  | None -> (
      match Hash.of_canonical_hex value with
      | Some hash -> (
          match List.find_opt (fun candidate -> Hash.equal hash candidate.hash) candidates with
          | Some candidate -> Ok candidate
          | None ->
              Error
                [
                  diagnostic "E1534"
                    (Printf.sprintf
                       "effect identity #%s is not one of the three released raw effects" value);
                ])
      | None ->
          Error
            [
              diagnostic "E1534"
                (Printf.sprintf "%S is neither a blessed display name nor a canonical effect hash"
                   value);
            ])

let effect_of_operation store operation =
  match Store.locate_internal store operation with
  | Ok
      { Store.decl = { Kernel.it = Kernel.DefEffect _; _ }; decl_hash; role = Store.Operation _; _ }
    ->
      Some decl_hash
  | Ok _ | Error _ -> None

let member_by_hash members hash =
  List.find_opt
    (fun (member : Governance_source_check.verified_member) -> Hash.equal member.member_hash hash)
    members

let rec contains_callable ty =
  match Types.repr ty with
  | Types.TArrow _ | Types.TResume _ | Types.TVariadicArrow _ -> true
  | Types.TCon (_, arguments) | Types.TTuple arguments -> List.exists contains_callable arguments
  | Types.TVar _ | Types.TSkolem _ -> false

let safe_external_leaf checker ~requested hash =
  match Check.force_term checker hash with
  | Error _ -> false
  | Ok scheme -> (
      match Types.repr (Types.instantiate ~level:0 scheme) with
      | Types.TArrow (parameters, row, result) ->
          let row = Types.repr_row row in
          (match row.tail with Types.RClosed -> true | Types.RVar _ | Types.RSkolem _ -> false)
          && (not
                (List.exists
                   (fun row_effect ->
                     Hash.equal row_effect workspace.hash || Hash.equal row_effect requested.hash)
                   row.effects))
          && (not (List.exists contains_callable parameters))
          && not (contains_callable result)
      | Types.TCon _ | Types.TTuple _ | Types.TResume _ | Types.TVariadicArrow _ | Types.TVar _
      | Types.TSkolem _ ->
          false)

let chain_key chain =
  let identities =
    chain.source_path @ [ chain.operation ] @ chain.forwarding_layers
    @ [ chain.live_leaf; chain.driver; chain.raw_effect ]
  in
  String.concat ":" (List.map (fun identity -> Hash.to_hex identity.hash) identities)

let compare_chain a b = String.compare (chain_key a) (chain_key b)

let dedupe_chains chains =
  let sorted = List.sort compare_chain chains in
  let rec loop previous acc = function
    | [] -> List.rev acc
    | chain :: rest ->
        let key = chain_key chain in
        if Option.equal String.equal previous (Some key) then loop previous acc rest
        else loop (Some key) (chain :: acc) rest
  in
  loop None [] sorted

let analyze ~effect_name source =
  match requested_effect effect_name with
  | Error _ as error -> error
  | Ok requested -> (
      let root_name, root_hash = Governance_source_check.verified_root source in
      let source_root = { name = root_name; hash = root_hash } in
      let topology = Governance_source_check.verified_topology source in
      let verified_report = Governance_source_check.verified_report source in
      let facade = { name = verified_report.facade.name; hash = verified_report.facade.hash } in
      let facade_operations =
        List.map
          (fun (operation : Governance_source_check.operation) ->
            { name = operation.name; hash = operation.hash })
          verified_report.operations
      in
      match topology with
      | Governance_source_check.Dry ->
          Ok
            {
              requested_effect = requested;
              source_root;
              topology = "direct-dry";
              facade;
              facade_operations;
              reached_operations = [];
              chains = [];
            }
      | Governance_source_check.Live | Governance_source_check.Forwarded_live _ ->
          let store = Governance_source_check.verified_store source in
          let checker = Governance_source_check.verified_checker source in
          let members = Governance_source_check.verified_members source in
          let budget = ref 100_000 in
          let chains = ref [] in
          let consume ?span () =
            decr budget;
            if !budget < 0 then
              Error [ diagnostic ?span "E1538" "more than 100000 reachable nodes were inspected" ]
            else Ok ()
          in
          let ( let* ) result fn = Result.bind result fn in
          let rec scan_list path group stack = function
            | [] -> Ok ()
            | expression :: rest ->
                let* () = scan_eval path group stack expression in
                scan_list path group stack rest
          and scan_eval path group stack expression =
            let* () = consume ?span:(Meta.span expression.Kernel.meta) () in
            match expression.Kernel.it with
            | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.Lam _ -> Ok ()
            | Kernel.Ann (body, _) | Kernel.Unquote body -> scan_eval path group stack body
            | Kernel.Tuple expressions -> scan_list path group stack expressions
            | Kernel.Let { value; body; _ } ->
                let* () = scan_eval path group stack value in
                scan_eval path group stack body
            | Kernel.Match (subject, clauses) ->
                let* () = scan_eval path group stack subject in
                scan_list path group stack (List.map (fun clause -> clause.Kernel.cbody) clauses)
            | Kernel.App (callee, arguments) ->
                let* () = scan_eval path group stack callee in
                let* () = scan_list path group stack arguments in
                invoke path group stack callee
            | Kernel.Handle { body; ret; ops } ->
                let rec check_handlers = function
                  | [] -> Ok ()
                  | clause :: rest -> (
                      match clause.Kernel.op with
                      | Kernel.Named name ->
                          Error
                            [
                              diagnostic ?span:(Meta.span clause.Kernel.ometa) "E1537"
                                (Printf.sprintf "handler operation %S remained unresolved" name);
                            ]
                      | Kernel.Hashed operation -> (
                          match effect_of_operation store operation with
                          | Some owner
                            when Hash.equal owner workspace.hash || Hash.equal owner requested.hash
                            ->
                              Error
                                [
                                  diagnostic ?span:(Meta.span clause.Kernel.ometa) "E1536"
                                    (Printf.sprintf "local handler operation #%s belongs to %s"
                                       (Hash.to_hex operation)
                                       (if Hash.equal owner workspace.hash then "Workspace"
                                        else requested.name));
                                ]
                          | _ -> check_handlers rest))
                in
                let* () = check_handlers ops in
                let* () = scan_eval path group stack body in
                let* () = scan_eval path group stack ret.Kernel.rbody in
                scan_list path group stack (List.map (fun clause -> clause.Kernel.obody) ops)
            | Kernel.Quote form -> scan_quote path group stack 0 form
          and scan_quote path group stack level form =
            let* () = consume ?span:(Meta.span form.Form.meta) () in
            if String.equal form.Form.head "unquote" && level = 0 then
              match form.Form.args with
              | [ Form.F splice ] -> (
                  match Kernel.expr_of_form splice with
                  | Ok expression -> scan_eval path group stack expression
                  | Error diagnostics ->
                      Error
                        [
                          diagnostic ?span:(Meta.span form.Form.meta) "E1537"
                            ("live unquote is not a kernel expression: "
                            ^ String.concat "; " (List.map Diag.to_cause_string diagnostics));
                        ])
              | _ ->
                  Error
                    [
                      diagnostic ?span:(Meta.span form.Form.meta) "E1537"
                        "live unquote does not contain exactly one form";
                    ]
            else
              let next_level =
                if String.equal form.Form.head "quote" then level + 1
                else if String.equal form.Form.head "unquote" then max 0 (level - 1)
                else level
              in
              let children =
                List.filter_map (function Form.F child -> Some child | _ -> None) form.Form.args
              in
              let rec scan_children = function
                | [] -> Ok ()
                | child :: rest ->
                    let* () = scan_quote path group stack next_level child in
                    scan_children rest
              in
              scan_children children
          and invoke path group stack callee =
            let* () = consume ?span:(Meta.span callee.Kernel.meta) () in
            match callee.Kernel.it with
            | Kernel.Ann (callee, _) -> invoke path group stack callee
            | Kernel.Lam (_, body) -> scan_eval path group stack body
            | Kernel.Ref (_, Kernel.Con) -> Ok ()
            | Kernel.Ref (hash, Kernel.Op) when Hash.equal hash read_file.hash ->
                record_chain path read_file
            | Kernel.Ref (hash, Kernel.Op) when Hash.equal hash write_file.hash ->
                record_chain path write_file
            | Kernel.Ref (hash, Kernel.Op) when Hash.equal hash fetch.hash ->
                record_chain path fetch
            | Kernel.Ref (hash, Kernel.Term) -> (
                match member_by_hash members hash with
                | Some _ -> invoke_member path stack hash
                | None ->
                    if safe_external_leaf checker ~requested hash then Ok ()
                    else
                      Error
                        [
                          diagnostic ?span:(Meta.span callee.Kernel.meta) "E1535"
                            (Printf.sprintf
                               "external callable #%s is open, effectful for the requested \
                                membrane, or transports a callable"
                               (Hash.to_hex hash));
                        ])
            | Kernel.GroupRef index -> (
                match List.nth_opt group index with
                | Some hash -> invoke_member path stack hash
                | None ->
                    Error
                      [
                        diagnostic ?span:(Meta.span callee.Kernel.meta) "E1537"
                          (Printf.sprintf "GroupRef %d is outside its %d-member source group" index
                             (List.length group));
                      ])
            | Kernel.Var name ->
                Error
                  [
                    diagnostic ?span:(Meta.span callee.Kernel.meta) "E1535"
                      (Printf.sprintf "call target %S is a variable" name);
                  ]
            | Kernel.Ref (hash, Kernel.Op) ->
                Error
                  [
                    diagnostic ?span:(Meta.span callee.Kernel.meta) "E1535"
                      (Printf.sprintf "call target #%s is not a released Workspace operation"
                         (Hash.to_hex hash));
                  ]
            | Kernel.Lit _ | Kernel.App _ | Kernel.Let _ | Kernel.Match _ | Kernel.Tuple _
            | Kernel.Handle _ | Kernel.Quote _ | Kernel.Unquote _ ->
                Error
                  [
                    diagnostic ?span:(Meta.span callee.Kernel.meta) "E1535"
                      "call target is returned, selected, transported, or otherwise higher-order";
                  ]
          and invoke_member path stack hash =
            match member_by_hash members hash with
            | None ->
                Error
                  [
                    diagnostic "E1535"
                      (Printf.sprintf "external callable #%s is not source-owned" (Hash.to_hex hash));
                  ]
            | Some member -> (
                if List.exists (Hash.equal member.member_hash) stack then Ok ()
                else
                  let identity = { name = member.member_name; hash = member.member_hash } in
                  let path = path @ [ identity ] in
                  let stack = member.member_hash :: stack in
                  match member.member_body.Kernel.it with
                  | Kernel.Lam (_, body) -> scan_eval path member.member_group stack body
                  | _ ->
                      Error
                        [
                          diagnostic
                            ?span:(Meta.span member.member_body.Kernel.meta)
                            "E1535"
                            (Printf.sprintf "source-owned callable %s is not a direct lambda"
                               member.member_name);
                        ])
          and record_chain path operation =
            let applicable =
              if Hash.equal requested.hash fs.hash then
                Hash.equal operation.hash read_file.hash
                || Hash.equal operation.hash write_file.hash
              else Hash.equal operation.hash fetch.hash
            in
            if not applicable then Ok ()
            else
              match
                Governance_source_check.canonical_workspace_driver ~operation:operation.hash
              with
              | None ->
                  Error
                    [
                      diagnostic "E1535"
                        (Printf.sprintf "Workspace operation #%s has no canonical driver"
                           (Hash.to_hex operation.hash));
                    ]
              | Some (_, driver_name, driver_hash) ->
                  let forwarding_layers, live_leaf =
                    match topology with
                    | Governance_source_check.Live -> ([], live)
                    | Governance_source_check.Forwarded_live count ->
                        (List.init count (fun _ -> forward_layer), live_layer)
                    | Governance_source_check.Dry -> ([], live)
                  in
                  chains :=
                    {
                      source_path = path;
                      operation;
                      forwarding_layers;
                      live_leaf;
                      driver = { name = driver_name; hash = driver_hash };
                      raw_effect = requested;
                    }
                    :: !chains;
                  Ok ()
          in
          let* () =
            scan_eval [ source_root ]
              (match member_by_hash members root_hash with
              | Some member -> member.member_group
              | None -> [])
              [ root_hash ]
              (Governance_source_check.verified_payload source)
          in
          let topology =
            match topology with
            | Governance_source_check.Live -> "direct-live"
            | Governance_source_check.Forwarded_live count ->
                Printf.sprintf "forwarded-live:%d" count
            | Governance_source_check.Dry -> "direct-dry"
          in
          let chains = dedupe_chains !chains in
          let effect_identity = function
            | "Fs" -> fs
            | "Net" -> net
            | "Secret" -> secret
            | name -> invalid_arg ("Bug_governance_why_effect unknown raw authority " ^ name)
          in
          let reached_operations =
            List.filter_map
              (fun (operation : Governance_source_check.operation) ->
                match
                  List.find_opt
                    (fun (chain : chain) -> Hash.equal chain.operation.hash operation.hash)
                    chains
                with
                | None -> None
                | Some chain ->
                    let index, normalizer_name, summarizer_name =
                      if Hash.equal operation.hash read_file.hash then
                        (0, "workspace.call-read", "workspace.summarize-read")
                      else if Hash.equal operation.hash write_file.hash then
                        (1, "workspace.call-write", "workspace.summarize-write")
                      else (2, "workspace.call-fetch", "workspace.summarize-fetch")
                    in
                    let raw_authority = List.map effect_identity operation.authority in
                    Some
                      {
                        operation = chain.operation;
                        raw_authority;
                        normalizer = { name = normalizer_name; hash = operation.normalizer };
                        summarizer = { name = summarizer_name; hash = operation.summarizer };
                        simulator = List.nth simulators index;
                        driver = chain.driver;
                        driver_introduced_raw_row = raw_authority;
                      })
              verified_report.operations
          in
          Ok
            {
              requested_effect = requested;
              source_root;
              topology;
              facade;
              facade_operations;
              reached_operations;
              chains;
            })

let hex hash = "#" ^ Hash.to_hex hash

let render_text report =
  let buffer = Buffer.create 512 in
  Printf.bprintf buffer "ok why-effect-v1 effect=%s %s root=%s %s topology=%s\n"
    report.requested_effect.name
    (hex report.requested_effect.hash)
    report.source_root.name (hex report.source_root.hash) report.topology;
  Printf.bprintf buffer "facade %s %s operations=%s\n" report.facade.name (hex report.facade.hash)
    (String.concat ","
       (List.map
          (fun operation -> operation.name ^ " " ^ hex operation.hash)
          report.facade_operations));
  List.iter
    (fun chain ->
      Printf.bprintf buffer "chain source=%s operation=%s %s"
        (String.concat " -> "
           (List.map (fun identity -> identity.name ^ " " ^ hex identity.hash) chain.source_path))
        chain.operation.name (hex chain.operation.hash);
      List.iter
        (fun layer -> Printf.bprintf buffer " layer=%s %s" layer.name (hex layer.hash))
        chain.forwarding_layers;
      Printf.bprintf buffer " live=%s %s driver=%s %s raw-effect=%s %s\n" chain.live_leaf.name
        (hex chain.live_leaf.hash) chain.driver.name (hex chain.driver.hash) chain.raw_effect.name
        (hex chain.raw_effect.hash))
    report.chains;
  List.iter
    (fun fact ->
      Printf.bprintf buffer
        "facts operation=%s %s authority=%s normalizer=%s %s summarizer=%s %s simulator=%s %s \
         driver=%s %s introduced-raw-row=%s\n"
        fact.operation.name (hex fact.operation.hash)
        (String.concat ","
           (List.map
              (fun authority -> authority.name ^ " " ^ hex authority.hash)
              fact.raw_authority))
        fact.normalizer.name (hex fact.normalizer.hash) fact.summarizer.name
        (hex fact.summarizer.hash) fact.simulator.name (hex fact.simulator.hash) fact.driver.name
        (hex fact.driver.hash)
        (String.concat ","
           (List.map
              (fun authority -> authority.name ^ " " ^ hex authority.hash)
              fact.driver_introduced_raw_row)))
    report.reached_operations;
  if report.chains = [] then
    Buffer.add_string buffer
      "chains none (no matching attributable Workspace applications; not runtime absence proof)\n";
  Buffer.add_string buffer
    "evidence-limits claim=static-source-attribution-only runtime-absence-proof=false \
     execution-provenance=false\n";
  Buffer.contents buffer

let identity_json identity =
  `Assoc [ ("name", `String identity.name); ("identity", `String (Hash.to_hex identity.hash)) ]

let render_json_v1 report =
  let chain_json chain =
    `Assoc
      [
        ("source_path", `List (List.map identity_json chain.source_path));
        ("operation", identity_json chain.operation);
        ("forwarding_layers", `List (List.map identity_json chain.forwarding_layers));
        ("live_leaf", identity_json chain.live_leaf);
        ("driver", identity_json chain.driver);
        ("raw_effect", identity_json chain.raw_effect);
        ( "membrane_layers",
          `List (List.map identity_json (chain.forwarding_layers @ [ chain.live_leaf ])) );
      ]
  in
  let operation_fact_json fact =
    `Assoc
      [
        ("operation", identity_json fact.operation);
        ("raw_authority", `List (List.map identity_json fact.raw_authority));
        ("normalizer", identity_json fact.normalizer);
        ("summarizer", identity_json fact.summarizer);
        ("simulator", identity_json fact.simulator);
        ("driver", identity_json fact.driver);
        ("driver_introduced_raw_row", `List (List.map identity_json fact.driver_introduced_raw_row));
      ]
  in
  let review_facts =
    `Assoc
      [
        ("schema", `String facts_schema);
        ("profile", `String "workspace-v0");
        ("facade", identity_json report.facade);
        ("facade_operations", `List (List.map identity_json report.facade_operations));
        ("reached_operations", `List (List.map operation_fact_json report.reached_operations));
        ("attribution_chains", `List (List.map chain_json report.chains));
      ]
  in
  let evidence_limits =
    `Assoc
      [
        ("claim", `String "static-source-attribution-only");
        ("runtime_absence_proof", `Bool false);
        ("execution_provenance", `Bool false);
      ]
  in
  Yojson.Safe.to_string
    (`Assoc
       [
         ("schema", `String schema);
         ("requested_effect", identity_json report.requested_effect);
         ("source_root", identity_json report.source_root);
         ("topology", `String report.topology);
         ("chains", `List (List.map chain_json report.chains));
         ("review_facts", review_facts);
         ("evidence_limits", evidence_limits);
       ])
