open Jacquard

type counters = {
  mutable fs_read : int;
  mutable fs_write : int;
  mutable net_fetch : int;
  mutable secret_read : int;
  mutable secret_expose : int;
  mutable events : string list;
}

let artifact_url = "https://artifacts.example/release"
let deployment_url = "https://deploy.example/apply"
let deployment_body = "artifact=sha256:artifact-v18"

let fail diagnostics =
  prerr_endline (String.concat "; " (List.map Diag.to_string diagnostics));
  exit 1

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let lookup store name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> failwith ("missing released name " ^ name)

let install_surface store file =
  let recovered = Surface_parse.recover_string ~file (read_file file) in
  let parsed =
    match Surface_parse.strict recovered with Ok value -> value | Error ds -> fail ds
  in
  let tops = match Surface_lower.lower_tops parsed with Ok value -> value | Error ds -> fail ds in
  List.iter
    (function
      | Kernel.Expr _ -> ()
      | Kernel.Decl declaration -> (
          match Resolve.resolve_decl (Store.names_view store) declaration with
          | Error ds -> fail ds
          | Ok declaration -> (
              match Store.put_decl store declaration with Ok _ -> () | Error ds -> fail ds)))
    tops

let expression store source =
  let form =
    match Reader.parse_one ~file:"gm18-live.jqd" source with
    | Ok value -> value
    | Error ds -> fail ds
  in
  let expression = match Kernel.expr_of_form form with Ok value -> value | Error ds -> fail ds in
  match Resolve.resolve_expr (Store.names_view store) expression with
  | Ok value -> value
  | Error ds -> fail ds

let eval ctx store source =
  match Eval.run_expr ctx (expression store source) with
  | Ok value -> value
  | Error error -> failwith (Runtime_err.to_string error)

let proposal_id = function
  | Value.VCon { name = "governance-proposal-v0"; args = _ :: Value.VHash id :: _; _ } -> id
  | value -> failwith ("expected canonical GovernanceProposal, got " ^ Value.show value)

let fresh_ctx store =
  let ctx = Eval.make_ctx store in
  (match Prelude.wire_builtins ctx with Ok () -> () | Error ds -> fail ds);
  ctx

let deployment_boundary store =
  let ctx = fresh_ctx store in
  let canonical = proposal_id (eval ctx store "(app (var deployment-proposal))") in
  let reconstructed =
    proposal_id
      (eval ctx store
         (Printf.sprintf
            "(app (var deployment-proposal-for) (app (var mk-request) (lit %S) (lit %S)))"
            deployment_url deployment_body))
  in
  if not (Hash.equal canonical reconstructed) then
    failwith "GM.18 typed deployment Request did not reconstruct the canonical proposal";
  canonical

let install_world store ctx counters =
  let event value = counters.events <- counters.events @ [ value ] in
  let artifact = eval ctx store "(app (var mk-response) (lit 200) (lit \"sha256:artifact-v18\"))" in
  let deployed =
    eval ctx store "(app (var mk-response) (lit 202) (lit \"live deployment accepted\"))"
  in
  Eval.register_root_handler ctx (lookup store "read" Resolve.KOp) (function
    | [ Value.VText "deploy/manifest.json" ] ->
        counters.fs_read <- counters.fs_read + 1;
        event "fs.read";
        Ok (Value.VText "release=v18")
    | _ -> Error (Runtime_err.Type_error "GM.18 expected the deployment manifest read"));
  Eval.register_root_handler ctx (lookup store "write" Resolve.KOp) (function
    | [ Value.VText "generated/deploy.conf"; Value.VText _ ] ->
        counters.fs_write <- counters.fs_write + 1;
        event "fs.write";
        Ok Value.unit_v
    | _ -> Error (Runtime_err.Type_error "GM.18 expected the generated configuration write"));
  Eval.register_root_handler ctx (lookup store "fetch" Resolve.KOp) (function
    | [ Value.VCon { name = "mk-request"; args = [ Value.VText url; Value.VText body ]; _ } ]
      when String.equal url artifact_url && String.equal body "release=v18" ->
        counters.net_fetch <- counters.net_fetch + 1;
        event "net.fetch";
        Ok artifact
    | [ Value.VCon { name = "mk-request"; args = [ Value.VText url; Value.VText body ]; _ } ]
      when String.equal url deployment_url && String.equal body deployment_body ->
        (* This exact typed request is the request used to construct [deployment-proposal].
           Validate it before incrementing the Net counter or entering the raw driver. *)
        counters.net_fetch <- counters.net_fetch + 1;
        event "net.fetch";
        Ok deployed
    | [ Value.VCon { name = "mk-request"; _ } ] ->
        Error
          (Runtime_err.Type_error
             "GM.18 request drifted from the exact artifact/deployment preauthorization boundary")
    | _ -> Error (Runtime_err.Type_error "GM.18 expected a typed Request"));
  Eval.register_root_handler ctx (lookup store "secret.read" Resolve.KOp) (fun _ ->
      counters.secret_read <- counters.secret_read + 1;
      event "secret.read";
      Ok (Value.VSecret (Secret.of_string "gm18-fixed-secret")));
  Eval.register_root_handler ctx (lookup store "secret.expose" Resolve.KOp) (function
    | [ Value.VSecret secret ] ->
        counters.secret_expose <- counters.secret_expose + 1;
        event "secret.expose";
        Ok (Value.VText (Secret.expose secret))
    | _ -> Error (Runtime_err.Type_error "GM.18 expected an opaque Secret"))

let make_ctx store counters =
  let ctx = fresh_ctx store in
  install_world store ctx counters;
  ctx

let reset counters =
  counters.fs_read <- 0;
  counters.fs_write <- 0;
  counters.net_fetch <- 0;
  counters.secret_read <- 0;
  counters.secret_expose <- 0;
  counters.events <- []

let list_length value =
  let rec loop count = function
    | Value.VCon { name = "nil"; args = []; _ } -> count
    | Value.VCon { name = "cons"; args = [ _; rest ]; _ } -> loop (count + 1) rest
    | _ -> failwith "malformed audit list"
  in
  loop 0 value

let outcome = function
  | Value.VCon
      {
        name = "ok";
        args =
          [
            Value.VTuple
              [
                Value.VCon
                  {
                    name = "ok";
                    args =
                      [ Value.VCon { name = "mk-response"; args = [ Value.VInt status; _ ]; _ } ];
                    _;
                  };
                entries;
              ];
          ];
        _;
      } ->
      (`Allowed status, list_length entries)
  | Value.VCon
      {
        name = "ok";
        args =
          [
            Value.VTuple
              [
                Value.VCon { name = "err"; args = [ Value.VCon { name = "tool-blocked"; _ } ]; _ };
                entries;
              ];
          ];
        _;
      } ->
      (`Refused, list_length entries)
  | value -> failwith ("unexpected live result " ^ Value.show value)

let run store ctx counters auto ask =
  reset counters;
  let source = Printf.sprintf "(app (var live-world) (var %s) (var %s))" auto ask in
  let result = outcome (eval ctx store source) in
  (result, counters.events)

let print_row label result audits counters =
  let result =
    match result with `Refused -> "refused" | `Allowed status -> "allowed:" ^ string_of_int status
  in
  Printf.printf
    "(\"agent/live-nested/%s\", \"%s\", \"audit\", %d, \"fs.read\", %d, \"fs.write\", %d, \
     \"net.fetch\", %d, \"secret.read\", %d, \"secret.expose\", %d)\n"
    label result audits counters.fs_read counters.fs_write counters.net_fetch counters.secret_read
    counters.secret_expose

let zero_counters counters =
  counters.fs_read = 0 && counters.fs_write = 0 && counters.net_fetch = 0
  && counters.secret_read = 0 && counters.secret_expose = 0 && counters.events = []

let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash_code value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]

let denied_decision proposal_id =
  form "denied-v1" [ hash_code proposal_id; lit "reviewer"; lit "deployment preflight denied" ]

let bridge_run ctx store queue =
  Governance_approval_bridge.run ctx ~file:queue ~allowed_approvers:[ "reviewer" ]
    (Eval.expr_state (expression store "(app (var deployment-approval-request))"))

let bridge_ok = function Ok value -> value | Error ds -> fail ds

let queue_records queue =
  match Governance_approval_queue.inspect_file ~file:queue |> bridge_ok with
  | Governance_approval_queue.Snapshot snapshot -> snapshot.records
  | Governance_approval_queue.Busy_inspection -> failwith "GM.18 approval queue stayed Busy"

let run_queue store counters =
  let queue = Filename.concat (Filename.get_temp_dir_name ()) "gm18-approval.queue" in
  if Sys.file_exists queue then failwith "GM.18 requires a fresh approval queue";
  let canonical = deployment_boundary store in
  let canonical_ctx = make_ctx store counters in
  reset counters;
  let submitted =
    match bridge_run canonical_ctx store queue |> bridge_ok with
    | Governance_approval_bridge.Awaiting_approval { proposal_id; _ } -> proposal_id
    | Governance_approval_bridge.Completed value ->
        failwith ("GM.18 preflight completed before review: " ^ Value.show value)
    | Governance_approval_bridge.Busy _ -> failwith "GM.18 fresh preflight was Busy"
    | Governance_approval_bridge.Stale_approval _ -> failwith "GM.18 fresh preflight was stale"
  in
  if not (Hash.equal canonical submitted) then
    failwith "GM.18 bridge submitted a non-canonical deployment proposal";
  if not (zero_counters counters) then failwith "GM.18 preflight entered live authority on Submit";
  ignore
    (Governance_approval_queue.decide_file ~file:queue ~proposal_id:submitted ~actor:"reviewer"
       ~decision:(denied_decision submitted)
    |> bridge_ok);
  reset counters;
  let denied_ctx = make_ctx store counters in
  (match bridge_run denied_ctx store queue |> bridge_ok with
  | Governance_approval_bridge.Completed
      (Value.VCon
         {
           name = "ok";
           args =
             [
               Value.VCon
                 {
                   name = "denied";
                   args = [ Value.VHash embedded; Value.VText "reviewer"; Value.VText _ ];
                   _;
                 };
             ];
           _;
         })
    when Hash.equal embedded submitted ->
      ()
  | Governance_approval_bridge.Completed value ->
      failwith ("GM.18 denial returned the wrong value: " ^ Value.show value)
  | Governance_approval_bridge.Awaiting_approval _ ->
      failwith "GM.18 durable denial was not delivered"
  | Governance_approval_bridge.Busy _ -> failwith "GM.18 denial delivery was Busy"
  | Governance_approval_bridge.Stale_approval _ -> failwith "GM.18 denial delivery was stale");
  if not (zero_counters counters) then failwith "GM.18 denied preflight entered live authority";
  let records = queue_records queue in
  if records <> 3 then failwith "GM.18 durable queue did not record Submit, Decision, Consume";
  Printf.printf
    "(\"agent/queue-denial\", \"proposal-id\", \"%s\", \"Denied\", \"queue-records\", %d, \
     \"fs.read\", %d, \"fs.write\", %d, \"net.fetch\", %d, \"secret.read\", %d, \"secret.expose\", \
     %d)\n"
    (Hash.to_hex submitted) records counters.fs_read counters.fs_write counters.net_fetch
    counters.secret_read counters.secret_expose

let run_live store counters =
  let canonical = deployment_boundary store in
  let ctx = make_ctx store counters in
  let (strict_result, strict_audits), strict_events = run store ctx counters "low" "low" in
  print_row "strict-outer" strict_result strict_audits counters;
  if strict_events <> [] then failwith "strict outer policy reached a raw driver";
  let (live_result, live_audits), events = run store ctx counters "medium" "high" in
  print_row "permissive-outer" live_result live_audits counters;
  let expected =
    [
      "fs.read";
      "secret.read";
      "secret.expose";
      "net.fetch";
      "fs.write";
      "secret.read";
      "secret.expose";
      "net.fetch";
    ]
  in
  if events <> expected then failwith ("unexpected live driver order: " ^ String.concat "," events);
  Printf.printf "live-driver-order %s\n" (String.concat ">" events);
  Printf.printf "live-deploy-boundary proposal-id %s validated-before-net\n" (Hash.to_hex canonical)

let () =
  if Array.length Sys.argv <> 5 then failwith "usage: live_evidence PRELUDE AGENT STORY MODE";
  let store_dir = Filename.concat (Filename.get_temp_dir_name ()) "gm18-live-store" in
  let store = match Store.open_store store_dir with Ok value -> value | Error ds -> fail ds in
  (match Prelude.load ~dir:Sys.argv.(1) store with Ok _ -> () | Error ds -> fail ds);
  install_surface store Sys.argv.(2);
  install_surface store Sys.argv.(3);
  let counters =
    { fs_read = 0; fs_write = 0; net_fetch = 0; secret_read = 0; secret_expose = 0; events = [] }
  in
  match Sys.argv.(4) with
  | "live" -> run_live store counters
  | "queue" -> run_queue store counters
  | mode -> failwith ("unknown GM.18 evidence mode " ^ mode)
