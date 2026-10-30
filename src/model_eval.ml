(* MODEL.1 evaluation and the model-result-v1 cache (docs/designs/model-dependencies.md). *)

let ( let* ) = Result.bind

type posterior_entry = { probability : float; value : Observation_transcript.field }

type outcome =
  | Value of Observation_transcript.field option
  | Posterior of { sampled : bool; explored : int; entries : posterior_entry list option }
  | Inference_failure of { sampled : bool; explored : int; failure : string }
  | Failure of string
  | Incomplete

let field_problem = function
  | Observation_transcript.Data _ -> None
  | Truncated _ -> Some "truncated"
  | Unsupported kind -> Some kind
  | Failure _ -> Some "failure"
  | Missing -> Some "missing"
  | Unfinished -> Some "fuel"

let uncacheable = function
  | Incomplete -> Some "fuel"
  | Value None | Posterior { entries = None; _ } -> Some "result-excluded"
  | Value (Some f) -> field_problem f
  | Posterior { entries = Some es; _ } -> List.find_map (fun e -> field_problem e.value) es
  | Inference_failure _ | Failure _ -> None

(* --- model-result-v1 --- *)

let mode sampled = if sampled then "sampled" else "complete"
let probability p = Printf.sprintf "%.17g" p

let field_text buf = function
  | Observation_transcript.Data s -> Printf.bprintf buf "data bytes=%d\n%s\n" (String.length s) s
  | Truncated { total; prefix } ->
      Printf.bprintf buf "truncated total=%d bytes=%d\n%s\n" total (String.length prefix) prefix
  | Unsupported kind -> Printf.bprintf buf "unsupported %s\n" kind
  | Failure code -> Printf.bprintf buf "failure %s\n" code
  | Missing -> Buffer.add_string buf "missing\n"
  | Unfinished -> Buffer.add_string buf "unfinished\n"

let outcome_text outcome =
  let buf = Buffer.create 256 in
  (match outcome with
  | Value None -> Buffer.add_string buf "outcome value excluded\n"
  | Value (Some f) ->
      Buffer.add_string buf "outcome value\n";
      field_text buf f
  | Posterior { sampled; explored; entries = None } ->
      Printf.bprintf buf "outcome posterior %s explored=%d excluded\n" (mode sampled) explored
  | Posterior { sampled; explored; entries = Some es } ->
      Printf.bprintf buf "outcome posterior %s explored=%d entries=%d\n" (mode sampled) explored
        (List.length es);
      List.iter
        (fun e ->
          Printf.bprintf buf "entry p=%s\n" (probability e.probability);
          field_text buf e.value)
        es
  | Inference_failure { sampled; explored; failure } ->
      Printf.bprintf buf "outcome inference %s %s explored=%d\n" failure (mode sampled) explored
  | Failure code -> Printf.bprintf buf "outcome failure code=%s\n" code
  | Incomplete -> Buffer.add_string buf "outcome incomplete bound=fuel\n");
  Buffer.contents buf

let serialize dependency outcome = Model_doc.serialize_dependency dependency ^ outcome_text outcome

let natural s =
  if s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s && (s = "0" || s.[0] <> '0') then
    int_of_string_opt s
  else None

let parse bytes =
  let fail fmt = Printf.ksprintf (fun m -> Error m) fmt in
  let marker = "\noutcome " in
  let n = String.length bytes and m = String.length marker in
  let rec find i =
    if i + m > n then None else if String.sub bytes i m = marker then Some i else find (i + 1)
  in
  match find 0 with
  | None -> fail "no outcome section"
  | Some i ->
      let* dependency = Model_doc.parse_dependency (String.sub bytes 0 (i + 1)) in
      let pos = ref (i + 1) in
      let line () =
        match String.index_from_opt bytes !pos '\n' with
        | Some j ->
            let l = String.sub bytes !pos (j - !pos) in
            pos := j + 1;
            Ok l
        | None -> fail "truncated line"
      in
      let take k =
        (* compare against what remains, so a huge declared length cannot overflow *)
        if k < 0 || k >= n - !pos || bytes.[!pos + k] <> '\n' then fail "bad payload length"
        else
          let s = String.sub bytes !pos k in
          pos := !pos + k + 1;
          Ok s
      in
      let field () =
        let* l = line () in
        match String.split_on_char ' ' l with
        | [ "data"; b ] when String.starts_with ~prefix:"bytes=" b -> (
            match natural (String.sub b 6 (String.length b - 6)) with
            | Some k -> Result.map (fun s -> Observation_transcript.Data s) (take k)
            | None -> fail "bad data length")
        | _ -> fail "only data fields are cached"
      in
      let int_after prefix s =
        if String.starts_with ~prefix s then
          natural (String.sub s (String.length prefix) (String.length s - String.length prefix))
        else None
      in
      let sampled = function
        | "sampled" -> Ok true
        | "complete" -> Ok false
        | s -> fail "bad mode %S" s
      in
      let* head = line () in
      let* outcome =
        match String.split_on_char ' ' head with
        | [ "outcome"; "value" ] ->
            let* f = field () in
            Ok (Value (Some f))
        | [ "outcome"; "posterior"; md; e; k ] -> (
            let* sampled = sampled md in
            match (int_after "explored=" e, int_after "entries=" k) with
            | Some explored, Some count ->
                let rec entries acc i =
                  if i = count then Ok (List.rev acc)
                  else
                    let* l = line () in
                    let* p =
                      match String.split_on_char ' ' l with
                      | [ "entry"; ps ] when String.starts_with ~prefix:"p=" ps -> (
                          let t = String.sub ps 2 (String.length ps - 2) in
                          match float_of_string_opt t with
                          | Some p when probability p = t -> Ok p
                          | _ -> fail "bad probability")
                      | _ -> fail "bad entry line"
                    in
                    let* value = field () in
                    entries ({ probability = p; value } :: acc) (i + 1)
                in
                let* es = entries [] 0 in
                Ok (Posterior { sampled; explored; entries = Some es })
            | _ -> fail "bad posterior line")
        | [ "outcome"; "inference"; failure; md; e ]
          when List.mem failure [ "impossible"; "exhausted"; "numerical" ] -> (
            let* sampled = sampled md in
            match int_after "explored=" e with
            | Some explored -> Ok (Inference_failure { sampled; explored; failure })
            | None -> fail "bad inference line")
        | [ "outcome"; "failure"; c ] when String.starts_with ~prefix:"code=" c ->
            Ok (Failure (String.sub c 5 (String.length c - 5)))
        | _ -> fail "not a cacheable outcome"
      in
      if !pos <> n then fail "trailing bytes"
      else if serialize dependency outcome <> bytes then fail "not in canonical form"
      else Ok (dependency, outcome)

(* --- evaluation --- *)

type status = Fresh | Cached | Uncacheable of string | Refused of Diag.t list
type evaluated = { name : string; key : Hash.t; status : status; outcome : outcome option }

let warning ~code cause =
  let summary, next_step =
    match code with
    | "W1800" ->
        ( "A model cache file was ignored.",
          "Nothing is needed: the result was recomputed and the file replaced." )
    | "W1803" ->
        ( "A damaged model history was repaired.",
          "Nothing is needed: the records before the damage were kept." )
    | "W1802" ->
        ( "A model result's history could not be written.",
          "Check that the cache directory is writable; the result itself is unaffected." )
    | "W1801" ->
        ( "A model result could not be written to the cache.",
          "Check that the cache directory is writable; the result itself is unaffected." )
    | _ -> raise (Diag.Bug_invalid_diagnostic ("unknown model cache code " ^ code))
  in
  Diag.warning ~domain:Diag.Project ~code ~summary ~cause ~next_step ~contrast:None ()

let refusal ~line ~name effects =
  Diag.error ~domain:Diag.Project ~code:"E1806"
    ~summary:"A model result needs a root grant that was not given."
    ~cause:
      (Printf.sprintf "line %d: result %s requires %s, which only a root grant provides" line name
         (String.concat ", " effects))
    ~next_step:"Evaluate with --allow for those effects; such results are never cached."
    ~contrast:None ()

let code_of d = match Diag.code d with Some c -> c | None -> "uncoded"

(* a failure without a public code is named by its stable kind, never by its message *)
let runtime_kind (e : Runtime_err.t) d =
  match Diag.code d with
  | Some c -> c
  | None -> (
      match e with
      | Runtime_err.Match_failure _ -> "match-failure"
      | Unhandled _ -> "unhandled"
      | Arity _ -> "arity"
      | Arithmetic _ -> "arithmetic"
      | Io _ -> "io"
      | Observe_at_root -> "observe-at-root"
      | Once_resumed_twice -> "once-resumed-twice"
      | Invalid_task_handle _ -> "invalid-task-handle"
      | Scheduler_error _ -> "scheduler"
      | Type_error _ -> "type-error"
      | Unresolved _ -> "unresolved"
      | Eval_error _ -> "eval"
      | Fuel_exhausted _ -> "fuel"
      | Alloc_exhausted _ -> "alloc"
      | Stale_capability _ -> "stale-capability"
      | Diagnostic _ -> "uncoded")

let is_fuel ds = List.exists (fun d -> Diag.code d = Some "E0919") ds

let run_one ~ctx ~allows ~seed ~out ~policy (r : Model_doc.resolved) =
  let project v =
    match Observation_policy.result policy with
    | Observation_policy.Ignore -> None
    | Observation_policy.Compare ->
        Some (Observation_transcript.field_of_value policy (Observation.of_value v))
  in
  let classify ~sampled = function
    | Error ds -> (
        if is_fuel ds then Incomplete
        else match ds with d :: _ -> Failure (code_of d) | [] -> Failure "uncoded")
    | Ok { Infer_dist.result; metadata } -> (
        let explored = metadata.Infer_dist.explored in
        match result with
        | Ok posterior ->
            let entries =
              match Observation_policy.result policy with
              | Observation_policy.Ignore -> None
              | Observation_policy.Compare ->
                  Some
                    (List.map
                       (fun (v, p) ->
                         {
                           probability = p;
                           value =
                             Observation_transcript.field_of_value policy (Observation.of_value v);
                         })
                       posterior.Infer_dist.entries)
            in
            Posterior { sampled; explored; entries }
        | Error failure ->
            let failure =
              match failure with
              | Infer_dist.Impossible -> "impossible"
              | Infer_dist.Exhausted -> "exhausted"
              | Infer_dist.Numeric _ -> "numerical"
            in
            Inference_failure { sampled; explored; failure })
  in
  Eval.with_invocation ~coverage:false ~fuel:r.Model_doc.dependency.Model_doc.fuel ctx
  @@ fun _invocation ->
  let rec grant = function
    | [] -> Ok ()
    | a :: rest ->
        let* () = Prelude.grant ctx a ~infer_cache:None ~out ~seed in
        grant rest
  in
  let* () = grant allows in
  let application = r.Model_doc.application in
  Ok
    (try
       match r.Model_doc.decl.Model_doc.r_driver with
       | Model_doc.Run -> (
           match Round_robin.run_expr ctx application with
           | Ok v -> Value (project v)
           | Error e ->
               let d = Runtime_err.to_diag e in
               if is_fuel [ d ] then Incomplete else Failure (runtime_kind e d))
       | Model_doc.Enumerate { max_branches } ->
           classify ~sampled:false
             (Infer_dist.enumerate_v1 ~max_branches ctx (Eval.expr_state application))
       | Model_doc.Lw { seed; samples } ->
           classify ~sampled:true
             (Infer_dist.likelihood_weighting_v1 ctx ~seed ~samples (fun () ->
                  Eval.expr_state application))
     with Fuel_meter.Exceeded -> Incomplete)

let max_cache_file = 64 * 1024 * 1024

let read_cache path =
  match Model_doc.read_bounded ~limit:max_cache_file path with
  | Ok bytes -> `Bytes bytes
  | Error `Absent -> `Absent
  | Error (`Unreadable reason) -> `Unreadable reason

let rec make_dirs dir =
  if not (Sys.file_exists dir) then (
    make_dirs (Filename.dirname dir);
    try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let random = lazy (Random.State.make_self_init ())

let write_atomic path bytes =
  let dir = Filename.dirname path in
  let tmp =
    Filename.concat dir
      (Printf.sprintf ".tmp-%d-%08x" (Unix.getpid ()) (Random.State.bits (Lazy.force random)))
  in
  try
    make_dirs dir;
    let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600 in
    Fun.protect
      ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
      (fun () ->
        let b = Bytes.unsafe_of_string bytes in
        let rec go off =
          if off < Bytes.length b then go (off + Unix.write fd b off (Bytes.length b - off))
        in
        go 0;
        Unix.fsync fd);
    Unix.rename tmp path;
    Ok ()
  with (Unix.Unix_error _ | Sys_error _) as e ->
    (try Sys.remove tmp with Sys_error _ -> ());
    Error (Printexc.to_string e)

let outcome_tag = function
  | Value _ -> "value"
  | Posterior _ -> "posterior"
  | Inference_failure { failure; _ } -> "inference-" ^ failure
  | Failure code -> "failure-" ^ code
  | Incomplete -> "incomplete"

let status_tag = function
  | Fresh -> "fresh"
  | Cached -> "cached"
  | Uncacheable reason -> "uncacheable-" ^ reason
  | Refused _ -> "refused"

let evaluate ?(record = fun _ ~outcome:_ -> Ok None) ~ctx ~allows ~seed ~cache ~out
    (prepared : Model_doc.prepared) =
  let warnings = ref [] in
  let warn ~code cause = warnings := warning ~code cause :: !warnings in
  let granted = Frontend.granted_effects prepared.Model_doc.store allows in
  let one (r : Model_doc.resolved) =
    let decl = r.Model_doc.decl in
    let name = decl.Model_doc.r_name in
    let dependency = r.Model_doc.dependency in
    let key = Model_doc.key dependency in
    let missing =
      List.filter (fun h -> not (List.exists (Hash.equal h) granted)) r.Model_doc.world
    in
    if missing <> [] then
      let effects = List.map (Check.name_of prepared.Model_doc.checker) missing in
      {
        name;
        key;
        status = Refused [ refusal ~line:decl.Model_doc.r_line ~name effects ];
        outcome = None;
      }
    else
      let path =
        Option.map
          (fun dir -> Filename.concat (Filename.concat dir "outcomes") (Hash.to_hex key))
          cache
      in
      let served =
        match (allows, path) with
        | [], Some path -> (
            match read_cache path with
            | `Absent -> None
            | `Unreadable reason ->
                warn ~code:"W1800" (Printf.sprintf "%s: %s" path reason);
                None
            | `Bytes bytes -> (
                match parse bytes with
                | Ok (stored, outcome)
                  when Model_doc.serialize_dependency stored
                       = Model_doc.serialize_dependency dependency ->
                    Some outcome
                | Ok _ ->
                    warn ~code:"W1800" (Printf.sprintf "%s: it records another result" path);
                    None
                | Error reason ->
                    warn ~code:"W1800" (Printf.sprintf "%s: %s" path reason);
                    None))
        | _ -> None
      in
      match served with
      | Some outcome -> { name; key; status = Cached; outcome = Some outcome }
      | None -> (
          match run_one ~ctx ~allows ~seed ~out ~policy:prepared.Model_doc.policy r with
          | Error ds -> { name; key; status = Refused ds; outcome = None }
          | Ok outcome ->
              let status =
                match (uncacheable outcome, allows, path) with
                | Some reason, _, _ -> Uncacheable reason
                | None, _ :: _, _ -> Uncacheable "root-grants"
                | None, [], None -> Uncacheable "no-cache"
                | None, [], Some path -> (
                    match write_atomic path (serialize dependency outcome) with
                    | Ok () -> Fresh
                    | Error reason ->
                        warn ~code:"W1801" (Printf.sprintf "%s: %s" path reason);
                        Uncacheable "write-failed")
              in
              { name; key; status; outcome = Some outcome })
  in
  let results =
    List.map2
      (fun r e ->
        (match (e.outcome, allows, cache) with
        | Some outcome, [], Some _ -> (
            match record r ~outcome:(status_tag e.status ^ " " ^ outcome_tag outcome) with
            | Ok None -> ()
            | Ok (Some note) -> warn ~code:"W1803" (Printf.sprintf "result %s: %s" e.name note)
            | Error reason -> warn ~code:"W1802" (Printf.sprintf "result %s: %s" e.name reason))
        | _ -> ());
        e)
      prepared.Model_doc.resolved
      (List.map one prepared.Model_doc.resolved)
  in
  (results, List.rev !warnings)

(* --- rendering --- *)

let status_text = function
  | Fresh -> "fresh"
  | Cached -> "cached"
  | Uncacheable reason -> Printf.sprintf "uncacheable (%s)" reason
  | Refused _ -> "refused"

let field_display = function
  | Observation_transcript.Data s -> s
  | Truncated { total; prefix } -> Printf.sprintf "%s... (%d bytes, truncated)" prefix total
  | Unsupported kind -> Printf.sprintf "<%s>" kind
  | Failure code -> Printf.sprintf "<failure %s>" code
  | Missing -> "<missing>"
  | Unfinished -> "<unfinished>"

let explored_text sampled explored =
  if sampled then Printf.sprintf "%d runs" explored else Printf.sprintf "%d paths explored" explored

let render_text e =
  let head = Printf.sprintf "%s: %s" e.name (status_text e.status) in
  let body =
    match e.outcome with
    | None -> []
    | Some (Value None) -> [ "value excluded by the policy" ]
    | Some (Value (Some f)) -> [ "value " ^ field_display f ]
    | Some (Posterior { sampled; explored; entries }) ->
        Printf.sprintf "posterior %s, %s" (mode sampled) (explored_text sampled explored)
        ::
        (match entries with
        | None -> [ "  excluded by the policy" ]
        | Some es ->
            List.map
              (fun en -> Printf.sprintf "  %.6f  %s" en.probability (field_display en.value))
              es)
    | Some (Inference_failure { sampled; explored; failure }) ->
        [ Printf.sprintf "%s (%s, %s)" failure (mode sampled) (explored_text sampled explored) ]
    | Some (Failure code) -> [ "failure " ^ code ]
    | Some Incomplete -> [ "incomplete: the fuel budget ran out" ]
  in
  head :: List.map (fun l -> "  " ^ l) body

let field_json = function
  | Observation_transcript.Data s -> `Assoc [ ("kind", `String "data"); ("text", `String s) ]
  | Truncated { total; prefix } ->
      `Assoc [ ("kind", `String "truncated"); ("total", `Int total); ("prefix", `String prefix) ]
  | Unsupported kind -> `Assoc [ ("kind", `String "unsupported"); ("opaque", `String kind) ]
  | Failure code -> `Assoc [ ("kind", `String "failure"); ("code", `String code) ]
  | Missing -> `Assoc [ ("kind", `String "missing") ]
  | Unfinished -> `Assoc [ ("kind", `String "unfinished") ]

let outcome_json = function
  | Value f ->
      `Assoc [ ("tag", `String "value"); ("value", Option.fold ~none:`Null ~some:field_json f) ]
  | Posterior { sampled; explored; entries } ->
      `Assoc
        [
          ("tag", `String "posterior");
          ("mode", `String (mode sampled));
          ("explored", `Int explored);
          ( "entries",
            match entries with
            | None -> `Null
            | Some es ->
                `List
                  (List.map
                     (fun en ->
                       `Assoc
                         [
                           ("probability", `String (probability en.probability));
                           ("value", field_json en.value);
                         ])
                     es) );
        ]
  | Inference_failure { sampled; explored; failure } ->
      `Assoc
        [
          ("tag", `String "inference");
          ("failure", `String failure);
          ("mode", `String (mode sampled));
          ("explored", `Int explored);
        ]
  | Failure code -> `Assoc [ ("tag", `String "failure"); ("code", `String code) ]
  | Incomplete -> `Assoc [ ("tag", `String "incomplete"); ("bound", `String "fuel") ]

let to_json results =
  let one e =
    let status, extra =
      match e.status with
      | Fresh -> ("fresh", [])
      | Cached -> ("cached", [])
      | Uncacheable reason -> ("uncacheable", [ ("reason", `String reason) ])
      | Refused ds -> ("refused", [ ("diagnostics", `List (List.map Diag.to_yojson ds)) ])
    in
    `Assoc
      ([
         ("name", `String e.name); ("key", `String (Hash.to_hex e.key)); ("status", `String status);
       ]
      @ extra
      @ [ ("outcome", Option.fold ~none:`Null ~some:outcome_json e.outcome) ])
  in
  Yojson.Safe.to_string
    (`Assoc
       [ ("format", `String "jacquard-model-eval-v1"); ("results", `List (List.map one results)) ])
