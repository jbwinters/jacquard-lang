(* HB.3 conformance kit: binds the synthetic HB.1 vectors to real fixture identities, plays them
   through the installed worker with a deterministic fake host, and renders executable transcripts.
   Shared by the generator executable and the Alcotest suite. *)

open Jacquard
module Host = Host_protocol_v0

exception Timeout

(* --- JSON helpers --- *)

let rec canonical = function
  | `Assoc fields ->
      `Assoc
        (List.sort
           (fun (a, _) (b, _) -> String.compare a b)
           (List.map (fun (key, value) -> (key, canonical value)) fields))
  | `List items -> `List (List.map canonical items)
  | json -> json

let to_string json = Yojson.Safe.to_string (canonical json)
let equal a b = String.equal (to_string a) (to_string b)

(* Diagnostic prose is Core-authored human text: the stable contract is the code, domain,
   severity, span, and schema, plus the host message suffix in the cause. *)
let prose_fields = [ "summary"; "cause"; "next_step"; "contrast" ]

let is_diagnostic = function
  | `Assoc fields -> List.assoc_opt "schema" fields = Some (`String "jacquard-diagnostic-v1")
  | _ -> false

let rec strip_prose json =
  match json with
  | `Assoc fields when is_diagnostic json ->
      `Assoc
        (List.filter_map
           (fun (key, value) ->
             if List.mem key prose_fields then None else Some (key, strip_prose value))
           fields)
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> (key, strip_prose value)) fields)
  | `List values -> `List (List.map strip_prose values)
  | json -> json

let equal_semantic a b = equal (strip_prose a) (strip_prose b)

(* Paths of diagnostic prose fields whose text differs between two semantically equal frames. *)
let prose_drift expected observed =
  let rec go path expected observed acc =
    match (expected, observed) with
    | `Assoc e, `Assoc o when is_diagnostic expected ->
        List.fold_left
          (fun acc key ->
            match (List.assoc_opt key e, List.assoc_opt key o) with
            | Some a, Some b when not (equal a b) -> (path ^ "/" ^ key) :: acc
            | _ -> acc)
          acc prose_fields
    | `Assoc e, `Assoc o ->
        List.fold_left
          (fun acc (key, a) ->
            match List.assoc_opt key o with Some b -> go (path ^ "/" ^ key) a b acc | None -> acc)
          acc e
    | `List e, `List o when List.length e = List.length o ->
        List.fold_left2
          (fun acc (i, a) b -> go (path ^ "/" ^ string_of_int i) a b acc)
          acc
          (List.mapi (fun i a -> (i, a)) e)
          o
    | _ -> acc
  in
  List.rev (go "" expected observed [])

let member = Yojson.Safe.Util.member
let text = Yojson.Safe.Util.to_string
let items = Yojson.Safe.Util.to_list
let integer = Yojson.Safe.Util.to_int

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel contents)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error _ -> ()

let bytes_of_hex hex =
  String.init
    (String.length hex / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub hex (2 * i) 2)))

let hex_of_bytes bytes =
  String.concat ""
    (List.init (String.length bytes) (fun i -> Printf.sprintf "%02x" (Char.code bytes.[i])))

(* --- the HB.1 vector document --- *)

type template = { direction : string; message : Yojson.Safe.t }
type positive = { positive_name : string; sequence : string list; terminal : string }

type hostile = {
  hostile_name : string;
  base : string;
  phase : string;
  expect : Yojson.Safe.t;
  mutation : Yojson.Safe.t;
}

type document = {
  hard_limits : Yojson.Safe.t;
  templates : (string * template) list;
  positives : positive list;
  hostiles : hostile list;
}

let load_vectors path =
  let json = Yojson.Safe.from_file path in
  let templates =
    match member "templates" json with
    | `Assoc fields ->
        List.map
          (fun (name, value) ->
            (name, { direction = text (member "direction" value); message = member "message" value }))
          fields
    | _ -> failwith "vectors: templates must be an object"
  in
  let positives =
    items (member "positive" json)
    |> List.map (fun item ->
        {
          positive_name = text (member "name" item);
          sequence = List.map text (items (member "sequence" item));
          terminal = text (member "terminal" item);
        })
  in
  let hostiles =
    items (member "hostile" json)
    |> List.map (fun item ->
        {
          hostile_name = text (member "name" item);
          base = text (member "base" item);
          phase = text (member "phase" item);
          expect = member "expect" item;
          mutation = member "mutation" item;
        })
  in
  { hard_limits = member "hard_limits" json; templates; positives; hostiles }

let rec expand_refs hard_limits = function
  | `Assoc [ ("$ref", `String "hard_limits") ] -> hard_limits
  | `Assoc fields ->
      `Assoc (List.map (fun (key, value) -> (key, expand_refs hard_limits value)) fields)
  | `List values -> `List (List.map (expand_refs hard_limits) values)
  | json -> json

(* --- kit identities --- *)

type identities = {
  ready : Hash.t;
  echo : Hash.t;
  twice : Hash.t;
  double : Hash.t;
  fail : Hash.t;
  world : Hash.t;
  send : Hash.t;
  int_type : Hash.t;
  text_type : Hash.t;
}

let identity_names =
  [
    ("kit-ready", Resolve.KTerm);
    ("kit-echo", Resolve.KTerm);
    ("kit-twice", Resolve.KTerm);
    ("kit-double", Resolve.KTerm);
    ("kit-fail", Resolve.KTerm);
    ("kit-world", Resolve.KEffect);
    ("send", Resolve.KOp);
    ("int", Resolve.KType);
    ("text", Resolve.KType);
  ]

let identities_of_store store =
  let lookup name kind =
    match Store.lookup_kind store name kind with
    | Some { Resolve.hash; _ } -> Ok hash
    | None -> Error (Printf.sprintf "kit store is missing `%s`" name)
  in
  let ( let* ) = Result.bind in
  let* ready = lookup "kit-ready" Resolve.KTerm in
  let* echo = lookup "kit-echo" Resolve.KTerm in
  let* twice = lookup "kit-twice" Resolve.KTerm in
  let* double = lookup "kit-double" Resolve.KTerm in
  let* fail = lookup "kit-fail" Resolve.KTerm in
  let* world = lookup "kit-world" Resolve.KEffect in
  let* send = lookup "send" Resolve.KOp in
  let* int_type = lookup "int" Resolve.KType in
  let* text_type = lookup "text" Resolve.KType in
  Ok { ready; echo; twice; double; fail; world; send; int_type; text_type }

let identities_json ids =
  `Assoc
    (List.map
       (fun (name, hash) -> (name, `String (Hash.to_hex hash)))
       [
         ("kit-ready", ids.ready);
         ("kit-echo", ids.echo);
         ("kit-twice", ids.twice);
         ("kit-double", ids.double);
         ("kit-fail", ids.fail);
         ("kit-world", ids.world);
         ("send", ids.send);
         ("int", ids.int_type);
         ("text", ids.text_type);
       ])

let synthetic character = String.make 64 character

(* The synthetic identities used by the frozen vectors and the kit member each one denotes. *)
let bindings ids =
  [
    (synthetic 'a', ("kit-ready", ids.ready));
    (synthetic 'd', ("kit-echo", ids.echo));
    (synthetic 'b', ("kit-world", ids.world));
    (synthetic 'c', ("send", ids.send));
    (synthetic '1', ("text", ids.text_type));
  ]

let bindings_json ids =
  `Assoc
    (List.map
       (fun (syn, (name, hash)) ->
         (syn, `Assoc [ ("member", `String name); ("identity", `String (Hash.to_hex hash)) ]))
       (bindings ids))

let bind ids value =
  List.fold_left
    (fun value (syn, (_, hash)) ->
      Str.global_replace (Str.regexp_string syn) (Hash.to_hex hash) value)
    value (bindings ids)

let rec substitute ids = function
  | `String value -> `String (bind ids value)
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> (key, substitute ids value)) fields)
  | `List values -> `List (List.map (substitute ids) values)
  | json -> json

(* --- JSON pointer mutations --- *)

let pointer_tokens path =
  match String.split_on_char '/' path with
  | "" :: tokens ->
      List.map
        (fun token ->
          Str.global_replace (Str.regexp_string "~1") "/"
            (Str.global_replace (Str.regexp_string "~0") "~" token))
        tokens
  | _ -> failwith ("invalid JSON pointer " ^ path)

type operation = Replace of Yojson.Safe.t | Add of Yojson.Safe.t | Remove

let rec mutate operation tokens json =
  match (tokens, json) with
  | [], _ -> ( match operation with Replace value | Add value -> value | Remove -> `Null)
  | [ key ], `Assoc fields -> (
      match operation with
      | Replace value ->
          `Assoc (List.map (fun (k, v) -> if String.equal k key then (k, value) else (k, v)) fields)
      | Add value ->
          if List.mem_assoc key fields then
            `Assoc
              (List.map (fun (k, v) -> if String.equal k key then (k, value) else (k, v)) fields)
          else `Assoc (fields @ [ (key, value) ])
      | Remove -> `Assoc (List.filter (fun (k, _) -> not (String.equal k key)) fields))
  | [ key ], `List values -> (
      let index = int_of_string key in
      match operation with
      | Replace value -> `List (List.mapi (fun i v -> if i = index then value else v) values)
      | Add value ->
          let before = List.filteri (fun i _ -> i < index) values in
          let after = List.filteri (fun i _ -> i >= index) values in
          `List (before @ [ value ] @ after)
      | Remove -> `List (List.filteri (fun i _ -> i <> index) values))
  | key :: rest, `Assoc fields ->
      `Assoc
        (List.map
           (fun (k, v) -> if String.equal k key then (k, mutate operation rest v) else (k, v))
           fields)
  | key :: rest, `List values ->
      let index = int_of_string key in
      `List (List.mapi (fun i v -> if i = index then mutate operation rest v else v) values)
  | _ -> failwith "JSON pointer does not resolve"

(* --- executable cases --- *)

type host_input = Frame of string * Yojson.Safe.t | Raw of string
type step = Core_frame of string | Host_input of host_input

type case = {
  name : string;
  kind : string;
  base : string option;
  phase : string option;
  sequence : string list;
  expect : Yojson.Safe.t;
  steps : step list;
  append_after_terminal : (string * Yojson.Safe.t) option;
  expected_core : (string * Yojson.Safe.t) list;
}

let frame_of doc ids name =
  let template = List.assoc name doc.templates in
  (template.direction, substitute ids (expand_refs doc.hard_limits template.message))

let steps_of doc ids ?mutation sequence =
  List.mapi
    (fun index name ->
      let direction, frame = frame_of doc ids name in
      if String.equal direction "core_to_host" then Core_frame name
      else
        match mutation with
        | Some (`Raw (at, bytes)) when at = index -> Host_input (Raw bytes)
        | Some (`Json (at, operation, path)) when at = index ->
            Host_input (Frame (name, mutate operation (pointer_tokens path) frame))
        | _ -> Host_input (Frame (name, frame)))
    sequence

let expected_core doc ids sequence =
  List.filter_map
    (fun name ->
      let direction, frame = frame_of doc ids name in
      if String.equal direction "core_to_host" then Some (name, frame) else None)
    sequence

let positive_case doc ids positive =
  {
    name = positive.positive_name;
    kind = "positive";
    base = None;
    phase = None;
    sequence = positive.sequence;
    expect = `Assoc [ ("terminal", `String positive.terminal) ];
    steps = steps_of doc ids positive.sequence;
    append_after_terminal = None;
    expected_core = expected_core doc ids positive.sequence;
  }

let hostile_case doc ids (hostile : hostile) =
  let base =
    match List.find_opt (fun p -> String.equal p.positive_name hostile.base) doc.positives with
    | Some base -> base
    | None -> failwith ("hostile base " ^ hostile.base ^ " is not a positive case")
  in
  let op = text (member "op" hostile.mutation) in
  let frame () = integer (member "frame" hostile.mutation) in
  let path () = text (member "path" hostile.mutation) in
  let mutation, append =
    match op with
    | "replace" ->
        (Some (`Json (frame (), Replace (member "value" hostile.mutation), path ())), None)
    | "add" -> (Some (`Json (frame (), Add (member "value" hostile.mutation), path ())), None)
    | "remove" -> (Some (`Json (frame (), Remove, path ())), None)
    | "raw_wire" ->
        (Some (`Raw (frame (), bytes_of_hex (text (member "wire_hex" hostile.mutation)))), None)
    | "append" ->
        let name = text (member "template" hostile.mutation) in
        (None, Some (name, snd (frame_of doc ids name)))
    | other -> failwith ("unknown mutation op " ^ other)
  in
  {
    name = hostile.hostile_name;
    kind = "hostile";
    base = Some hostile.base;
    phase = Some hostile.phase;
    sequence = base.sequence;
    expect = hostile.expect;
    steps = steps_of doc ids ?mutation base.sequence;
    append_after_terminal = append;
    expected_core = expected_core doc ids base.sequence;
  }

let cases doc ids =
  List.map (positive_case doc ids) doc.positives @ List.map (hostile_case doc ids) doc.hostiles

(* --- the fake host --- *)

type observed = {
  core_frames : Yojson.Safe.t list;
  exit_code : int option;
  signal : int option;
  stderr : string;
  host_refusal : string option;
  skipped_after_terminal : int;
  write_failure : bool;
}

let is_terminal json =
  match member "kind" json with
  | `String ("outcome" | "fatal" | "shutdown_ack") -> true
  | _ -> false

let encode json =
  match Host.encode_frame_bytes ~limits:Host.hard_limits json with
  | Ok bytes -> bytes
  | Error diagnostics -> failwith (String.concat "\n" (List.map Diag.to_string diagnostics))

let with_deadline seconds run =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Timeout)) in
  ignore (Unix.alarm seconds);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigalrm previous)
    run

let fresh_path =
  let serial = ref 0 in
  fun label ->
    incr serial;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-host-kit-%s-%d-%d" label (Unix.getpid ()) !serial)

(* Play one case in lockstep against a freshly spawned worker. The host writes only when the
   sequence says it is the host's turn and never after it has observed a terminal frame. *)
let play ~binary ~store case =
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let stderr_path = fresh_path "stderr" in
  let err_fd = Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let pid =
    Unix.create_process binary [| binary; "host"; "worker"; "--store"; store |] in_r out_w err_fd
  in
  Unix.close in_r;
  Unix.close out_w;
  Unix.close err_fd;
  let input = Unix.out_channel_of_descr in_w in
  let output = Unix.in_channel_of_descr out_r in
  let previous = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  let frames = ref [] in
  let terminal = ref false in
  let refusal = ref None in
  let skipped = ref 0 in
  let write_failure = ref false in
  let input_open = ref true in
  let read_frame () =
    match Host.read_frame ~limits:Host.hard_limits output with
    | Ok json ->
        frames := json :: !frames;
        if is_terminal json then terminal := true;
        true
    | Error _ -> false
  in
  let close_input () =
    if !input_open then begin
      input_open := false;
      close_out_noerr input
    end
  in
  let write bytes =
    if !input_open then (
      try
        output_string input bytes;
        flush input
      with Sys_error _ ->
        write_failure := true;
        close_input ())
  in
  let run () =
    List.iter
      (function
        | Core_frame _ -> ignore (read_frame ())
        | Host_input (Raw bytes) ->
            write bytes;
            close_input ()
        | Host_input (Frame (_, json)) -> if !terminal then incr skipped else write (encode json))
      case.steps;
    (match case.append_after_terminal with
    | Some (_, json) -> if !terminal then refusal := Some "E1608" else write (encode json)
    | None -> ());
    close_input ();
    while read_frame () do
      ()
    done
  in
  let reaped = ref None in
  let reap () =
    match !reaped with
    | Some status -> status
    | None ->
        let status = snd (Unix.waitpid [] pid) in
        reaped := Some status;
        status
  in
  let status =
    Fun.protect
      ~finally:(fun () ->
        close_input ();
        close_in_noerr output;
        Sys.set_signal Sys.sigpipe previous;
        (* any other failure must still reap the worker and drop its operator file *)
        (if Option.is_none !reaped then
           try
             Unix.kill pid Sys.sigkill;
             ignore (reap ())
           with Unix.Unix_error _ -> ());
        ())
      (fun () ->
        (try with_deadline 30 run
         with Timeout ->
           Unix.kill pid Sys.sigkill;
           frames := `Assoc [ ("kind", `String "fake-host-timeout") ] :: !frames);
        reap ())
  in
  let stderr = if Sys.file_exists stderr_path then read_file stderr_path else "" in
  if Sys.file_exists stderr_path then Sys.remove stderr_path;
  {
    core_frames = List.rev !frames;
    exit_code = (match status with Unix.WEXITED code -> Some code | _ -> None);
    signal = (match status with Unix.WSIGNALED signal -> Some signal | _ -> None);
    stderr;
    host_refusal = !refusal;
    skipped_after_terminal = !skipped;
    write_failure = !write_failure;
  }

(* --- observed summary and conformance --- *)

let first_code diagnostics =
  match diagnostics with
  | first :: _ -> ( match member "code" first with `String code -> Some code | _ -> None)
  | [] -> None

let summary observed =
  let terminal = List.find_opt is_terminal observed.core_frames in
  let kind = Option.map (fun json -> text (member "kind" json)) terminal in
  let primary_code =
    match terminal with
    | Some json when kind = Some "fatal" -> first_code (items (member "diagnostics" json))
    | Some json when kind = Some "outcome" -> (
        match member "kind" (member "result" json) with
        | `String "error" -> first_code (items (member "diagnostics" (member "result" json)))
        | _ -> None)
    | _ -> None
  in
  let terminal_class =
    match terminal with
    | Some json when kind = Some "outcome" ->
        Some (text (member "terminal" (member "core" (member "evidence" json))))
    | Some _ when kind = Some "fatal" -> Some "fatal"
    | Some _ when kind = Some "shutdown_ack" -> Some "shutdown"
    | _ -> None
  in
  let count predicate = List.length (List.filter predicate observed.core_frames) in
  let effect_requests = count (fun json -> member "kind" json = `String "effect_request") in
  let terminal_frames = count is_terminal in
  (kind, primary_code, terminal_class, effect_requests, terminal_frames)

(* Spec section 8: the exact decoded host message must end the diagnostic cause. *)
let host_message_suffix_honoured case observed =
  let messages =
    List.filter_map
      (function
        | Host_input (Frame (_, json)) when member "kind" json = `String "effect_failure" ->
            Some (text (member "message" json))
        | _ -> None)
      case.steps
  in
  match (messages, List.find_opt is_terminal observed.core_frames) with
  | [], _ | _, None -> true
  | message :: _, Some terminal -> (
      match member "kind" terminal with
      | `String "outcome" -> (
          match member "diagnostics" (member "result" terminal) with
          | `List (first :: _) -> (
              match member "cause" first with
              | `String cause -> Filename.check_suffix cause message
              | _ -> false)
          | _ -> false)
      | _ -> false)

let conforms case observed =
  let _, primary_code, terminal_class, effect_requests, terminal_frames = summary observed in
  match case.kind with
  | "positive" ->
      let expected = text (member "terminal" case.expect) in
      let observed_core =
        List.filter
          (fun json -> member "kind" json <> `String "fake-host-timeout")
          observed.core_frames
      in
      terminal_class = Some expected && observed.exit_code = Some 0
      && List.length observed_core = List.length case.expected_core
      && List.for_all2
           (fun (_, expected) actual -> equal_semantic expected actual)
           case.expected_core observed_core
      && host_message_suffix_honoured case observed
  | _ ->
      let code = text (member "code" case.expect) in
      let before = integer (member "effect_requests_before_failure" case.expect) in
      let max_terminals = integer (member "terminal_frames_max" case.expect) in
      let forbid = Yojson.Safe.Util.to_bool (member "forbid_outside_action" case.expect) in
      let expected_exit = if String.equal code "E1611" then 74 else 0 in
      effect_requests = before && terminal_frames <= max_terminals
      && ((not forbid) || effect_requests = 0)
      && observed.exit_code = Some expected_exit
      &&
      if case.phase = Some "terminal" then
        observed.host_refusal = Some code && terminal_class = Some "ok"
      else primary_code = Some code

let transcript_of case observed =
  let kind, primary_code, terminal_class, effect_requests, terminal_frames = summary observed in
  let host_input =
    List.mapi
      (fun index step ->
        match step with
        | Core_frame name ->
            `Assoc
              [
                ("step", `Int index);
                ("direction", `String "core_to_host");
                ("template", `String name);
              ]
        | Host_input (Frame (name, json)) ->
            `Assoc
              [
                ("step", `Int index);
                ("direction", `String "host_to_core");
                ("template", `String name);
                ("frame", canonical json);
              ]
        | Host_input (Raw bytes) ->
            `Assoc
              [
                ("step", `Int index);
                ("direction", `String "host_to_core");
                ("raw_hex", `String (hex_of_bytes bytes));
              ])
      case.steps
    @
    match case.append_after_terminal with
    | Some (name, json) ->
        [
          `Assoc
            [
              ("step", `Int (List.length case.steps));
              ("direction", `String "host_to_core");
              ("template", `String name);
              ("frame", canonical json);
              ("after_terminal", `Bool true);
            ];
        ]
    | None -> []
  in
  let optional = function Some value -> `String value | None -> `Null in
  `Assoc
    [
      ("name", `String case.name);
      ("kind", `String case.kind);
      ("base", optional case.base);
      ("phase", optional case.phase);
      ("sequence", `List (List.map (fun name -> `String name) case.sequence));
      ("expect", canonical case.expect);
      ("host_input", `List host_input);
      ("core_output", `List (List.map canonical observed.core_frames));
      ("exit_status", match observed.exit_code with Some code -> `Int code | None -> `Null);
      ( "observed",
        `Assoc
          [
            ("terminal_kind", optional kind);
            ("primary_code", optional primary_code);
            ("terminal", optional terminal_class);
            ("effect_requests", `Int effect_requests);
            ("terminal_frames", `Int terminal_frames);
            ("host_local_refusal", optional observed.host_refusal);
            ("host_inputs_skipped_after_terminal", `Int observed.skipped_after_terminal);
          ] );
      ( "prose_drift",
        `List
          (if
             String.equal case.kind "positive"
             && List.length case.expected_core = List.length observed.core_frames
           then
             List.concat
               (List.map2
                  (fun (template, expected) actual ->
                    List.map (fun path -> `String (template ^ path)) (prose_drift expected actual))
                  case.expected_core observed.core_frames)
           else []) );
      ("status", `String (if conforms case observed then "conforms" else "diverges"));
    ]

(* --- the kit store --- *)

let default_binary () =
  match Sys.getenv_opt "JACQUARD" with
  | Some binary -> binary
  | None ->
      List.find_opt Sys.file_exists [ "_build/default/bin/main.exe"; "../bin/main.exe" ]
      |> Option.value ~default:"jacquard"

let kit_dir () =
  if Sys.file_exists "spec/host-protocol-v0/kit" then "spec/host-protocol-v0/kit"
  else "../spec/host-protocol-v0/kit"

let prelude_dir () = if Sys.file_exists "prelude" then "prelude" else "../prelude"

(* Follow the published recipe exactly: `jacquard run fixtures.jac --store DIR`. *)
let build_store ~binary ~fixtures ~prelude ~store =
  let absolute path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
  in
  let env =
    Array.append
      [| "JACQUARD_PRELUDE=" ^ absolute prelude; "TMPDIR=" ^ Filename.get_temp_dir_name () |]
      (Array.of_list
         (List.filter
            (fun entry ->
              not
                (String.starts_with ~prefix:"JACQUARD_PRELUDE=" entry
                || String.starts_with ~prefix:"TMPDIR=" entry))
            (Array.to_list (Unix.environment ()))))
  in
  let null = Unix.openfile Filename.null [ Unix.O_RDWR ] 0 in
  let pid =
    Unix.create_process_env binary
      [| binary; "run"; fixtures; "--store"; store |]
      env null null Unix.stderr
  in
  Unix.close null;
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED code -> Error (Printf.sprintf "recipe exited %d" code)
  | _ -> Error "recipe was killed"

let manifest ~ids ~doc ~transcripts ~pending =
  `Assoc
    [
      ("schema", `String "jacquard-host-kit-v0");
      ("protocol", `String Host.protocol);
      ("carrier", `String Host.carrier);
      ("core_version", `String Version.version);
      ( "recipe",
        `Assoc
          [
            ("fixtures", `String "fixtures.jac");
            ("command", `String "jacquard run fixtures.jac --store DIR");
            ("prelude", `String "the prelude shipped with the same Core release");
            ("worker", `String "jacquard host worker --store DIR");
          ] );
      ("identities", identities_json ids);
      ("bindings", bindings_json ids);
      ("hard_limits", canonical doc.hard_limits);
      ("vectors", `String "../vectors.json");
      ("transcripts", `String "transcripts.json");
      ("transcript_count", `Int (List.length transcripts));
      ( "host_owned",
        `List
          (List.map
             (fun value -> `String value)
             [
               "operator text on the worker's standard error";
               "the exact moment a carrier loss is observed";
               "any run identifier, timestamp, peer identity, or receipt an adapter records \
                outside the Core frames";
             ]) );
      ( "diagnostic_prose",
        `Assoc
          [
            ("normative", `Bool false);
            ( "compared",
              `List
                (List.map (fun f -> `String f) [ "schema"; "domain"; "code"; "severity"; "span" ])
            );
            ( "cause_suffix_rule",
              `String "an effect_failure message must end the first diagnostic's cause" );
            ( "drift",
              `List
                (List.concat_map
                   (fun transcript ->
                     List.map
                       (fun path ->
                         `Assoc [ ("transcript", member "name" transcript); ("path", path) ])
                       (items (member "prose_drift" transcript)))
                   transcripts) );
          ] );
      ("pending_decisions", `List pending);
    ]
