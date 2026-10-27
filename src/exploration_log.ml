(* EXP.1 exploration-log-v1: an opt-in recording of every root-reaching operation and Dist choice
   of one run, with the source span of the application that performed it
   (docs/exploration-log.md). *)

let format_version = 1

exception Bound_reached of string

type kind = Operation_step | Choice_step | Observe_step

let kind_name = function
  | Operation_step -> "operation"
  | Choice_step -> "choice"
  | Observe_step -> "observe"

type step = {
  index : int;
  kind : kind;
  operation : Hash.t;
  name : string;
  site : Span.t option;
  arguments : (int * Observation_transcript.field) list;
  mutable result : Observation_transcript.field option;
  wants_result : bool;  (** the policy keeps this operation's result *)
  mutable output : (Buffer.t * int ref) option;  (** retained prefix, total bytes *)
}

type t = {
  policy : Observation_policy.t;
  record_output : bool;
  max_steps : int;
  max_bytes : int;
  sample : Hash.t option;
  observe : Hash.t option;
  expose : Hash.t option;
  mutable secrets : string list;
      (** plaintext that [secret.expose] returned: never recorded, and redacted from every later
          field *)
  mutable secret_unknown : bool;
      (** a [secret.expose] result could not be projected (fuel), so its plaintext is unknown: every
          later field is recorded as a secret and later output is dropped *)
  mutable steps : step list;  (** newest first *)
  mutable count : int;
  calls : (int, step) Hashtbl.t;
  mutable bytes : int;
  mutable bounded : string option;
}

(* the recording default: every operation with its arguments and result; output only with
   --record-output *)
let default_policy =
  match
    Observation_policy.make ~result:Observation_policy.Compare ~field_bytes:4096
      ~unlisted:
        (Some
           {
             Observation_policy.arguments = Observation_policy.All_arguments;
             result = Observation_policy.Compare;
             output = Observation_policy.Compare;
           })
      ~interface:None []
  with
  | Ok policy -> policy
  | Error _ -> raise (Invalid_argument "Exploration_log.default_policy")

let create ~policy ~record_output ~max_steps ~max_bytes ~sample ~observe ~expose =
  {
    expose;
    secrets = [];
    secret_unknown = false;
    policy;
    record_output;
    max_steps;
    max_bytes;
    sample;
    observe;
    steps = [];
    count = 0;
    calls = Hashtbl.create 64;
    bytes = 0;
    bounded = None;
  }

let field_size = function
  | Observation_transcript.Data s -> String.length s
  | Truncated { prefix; _ } -> String.length prefix
  | Unsupported _ | Failure _ | Missing | Unfinished -> 0

(* a fixed per-line allowance keeps the byte bound meaningful for steps with empty fields *)
let line_cost = 64

(* a field or step is admitted only if it fits: nothing past --max-bytes is retained *)
let charge t n =
  if t.bytes + n > t.max_bytes then (
    t.bounded <- Some "bytes";
    raise (Bound_reached "bytes"));
  t.bytes <- t.bytes + n

(* a recorded field holds the data-v1 rendering, where text is quoted and escaped, so the escaped
   spelling is redacted as well as the raw plaintext (which output bytes carry) *)
let learn_secret t plaintext =
  let escaped = Printer.escape_text plaintext in
  t.secrets <-
    List.sort_uniq String.compare (List.filter (fun s -> s <> "") [ plaintext; escaped ] @ t.secrets)

(* the bounded field of [text]: all of it, or the policy's first [field_bytes] bytes *)
let bounded t text =
  let limit = Observation_policy.field_bytes t.policy in
  if String.length text <= limit then Observation_transcript.Data text
  else
    Observation_transcript.Truncated
      { total = String.length text; prefix = String.sub text 0 limit }

(* a value's recorded field: unsupported values as OBS.1 records them; otherwise its full data-v1
   rendering with exposed secrets redacted, then bounded, so a field never exceeds the policy's
   limit and its total is that of the redacted text *)
let value_field t v =
  (* as OBS.1 does, a projection that runs out of fuel is kept as [unfinished]; the evaluator then
     stops the run on its own exhausted budget *)
  if t.secret_unknown then Observation_transcript.Unsupported "secret"
  else
    match Observation_transcript.field_of_value t.policy v with
    | exception Fuel_meter.Exceeded -> Observation_transcript.Unfinished
    | (Data _ | Truncated _) when t.secrets <> [] -> (
        match Observation_transcript.render_data v with
        | exception Fuel_meter.Exceeded -> Observation_transcript.Unfinished
        | text -> bounded t (Relate.redact ~secrets:t.secrets text))
    | field -> field

let projected_arguments t (rule : Observation_policy.rule) values =
  let field v = value_field t v in
  match rule.arguments with
  | Observation_policy.No_arguments -> []
  | Observation_policy.All_arguments -> List.mapi (fun i v -> (i, field v)) (Lazy.force values)
  | Observation_policy.Selected_arguments positions ->
      let values = Lazy.force values in
      List.map
        (fun i ->
          match List.nth_opt values i with
          | Some v -> (i, field v)
          | None -> (i, Observation_transcript.Missing))
        positions

let same h = function Some h' -> Hash.equal h h' | None -> false

let span_text (s : Span.t) =
  Printf.sprintf "%s:%d:%d-%d:%d" s.Span.file s.start_pos.line s.start_pos.col s.end_pos.line
    s.end_pos.col

let on_event t (event : Observation.event) =
  if Option.is_none t.bounded then
    match event with
    | Observation.Operation { call; operation; name; arguments; site } -> (
        match Observation_policy.rule_for t.policy operation with
        | None -> ()
        | Some rule ->
            if t.count >= t.max_steps then (
              t.bounded <- Some "steps";
              raise (Bound_reached "steps"));
            let kind =
              if same operation t.sample then Choice_step
              else if same operation t.observe then Observe_step
              else Operation_step
            in
            (* forcing the argument list itself can exhaust fuel: the operation is still kept, with
               its arguments unfinished (OBS.1 records all-arguments as position 0) *)
            let arguments =
              match projected_arguments t rule arguments with
              | args -> args
              | exception Fuel_meter.Exceeded -> (
                  (* OBS.1's convention: all-arguments as position 0, selected positions each *)
                  match rule.arguments with
                  | Observation_policy.No_arguments -> []
                  | Observation_policy.All_arguments -> [ (0, Observation_transcript.Unfinished) ]
                  | Observation_policy.Selected_arguments positions ->
                      List.map (fun i -> (i, Observation_transcript.Unfinished)) positions)
            in
            let step =
              {
                index = t.count;
                kind;
                operation;
                name;
                site;
                arguments;
                result = None;
                wants_result = rule.result = Observation_policy.Compare;
                output = None;
              }
            in
            charge t
              ((3 * line_cost)
              (* a kept result is reserved now: [finish] may write it as [missing] *)
              + (if rule.result = Observation_policy.Compare then line_cost else 0)
              + String.length name
              + (match site with Some s -> String.length (span_text s) | None -> 0)
              + List.fold_left (fun acc (_, f) -> acc + line_cost + field_size f) 0 arguments);
            t.steps <- step :: t.steps;
            t.count <- t.count + 1;
            Hashtbl.replace t.calls call step)
    | Observation.Result { call; operation; result } -> (
        (* exposed plaintext is learned from every [secret.expose] result, whatever the policy
           keeps, so no later field or output can carry it *)
        (if same operation t.expose then
           match Lazy.force result with
           | Ok (Observation.Text plaintext) when plaintext <> "" -> learn_secret t plaintext
           | _ -> ()
           | exception Fuel_meter.Exceeded -> t.secret_unknown <- true);
        match (Hashtbl.find_opt t.calls call, Observation_policy.rule_for t.policy operation) with
        | Some step, Some { result = Observation_policy.Compare; _ } ->
            let field =
              match Lazy.force result with
              | exception Fuel_meter.Exceeded ->
                  if same operation t.expose then Observation_transcript.Unsupported "secret"
                  else Observation_transcript.Unfinished
              | Ok _ when same operation t.expose -> Observation_transcript.Unsupported "secret"
              | Ok v -> value_field t v
              | Error error ->
                  Observation_transcript.Failure (Diag.code_or_uncoded (Runtime_err.to_diag error))
            in
            charge t (field_size field);
            step.result <- Some field
        | _ -> ())
    | Observation.Output { call; operation; bytes } -> (
        match (Hashtbl.find_opt t.calls call, Observation_policy.rule_for t.policy operation) with
        | Some step, Some { output = Observation_policy.Compare; _ }
          when t.record_output && not t.secret_unknown ->
            let bytes = if t.secrets = [] then bytes else Relate.redact ~secrets:t.secrets bytes in
            (* output keeps at most the policy's field limit, like every other field *)
            let limit = Observation_policy.field_bytes t.policy in
            let room =
              match step.output with
              | Some (buf, _) -> max 0 (limit - Buffer.length buf)
              | None -> limit
            in
            let kept = if String.length bytes <= room then bytes else String.sub bytes 0 room in
            (* the output line's allowance is charged with its first chunk, before any state is
               kept *)
            charge t ((if Option.is_none step.output then line_cost else 0) + String.length kept);
            let buf, total =
              match step.output with
              | Some o -> o
              | None ->
                  let o = (Buffer.create 64, ref 0) in
                  step.output <- Some o;
                  o
            in
            Buffer.add_string buf kept;
            total := !total + String.length bytes
        | _ -> ())

(* --- the log --- *)

type entry = {
  e_index : int;
  e_kind : kind;
  e_operation : Hash.t;
  e_name : string;
  e_site : string option;  (** [file:line:col-line:col] *)
  e_arguments : (int * Observation_transcript.field) list;
  e_result : Observation_transcript.field option;
  e_output : Observation_transcript.field option;
}

type ending = Exit of int | Bounded of string

type log = {
  program : string;  (** the [program] line *)
  seed : int;
  grants : string;  (** the [--allow] names as given, comma-joined; a framed payload *)
  policy_identity : Hash.t;
  output_recorded : bool;
  entries : entry list;
  ending : ending;
}

let finish t ~program ~seed ~grants ~exit_status =
  {
    program;
    seed;
    grants;
    policy_identity = Observation_policy.identity t.policy;
    output_recorded = t.record_output;
    entries =
      List.rev_map
        (fun s ->
          {
            e_index = s.index;
            e_kind = s.kind;
            e_operation = s.operation;
            e_name = s.name;
            e_site = Option.map span_text s.site;
            e_arguments = s.arguments;
            (* as in OBS.1, a kept result that never arrived (an inference driver captured the
               choice and resumed it itself, or the run stopped first) is [missing] *)
            e_result =
              (match s.result with
              | None when s.wants_result -> Some Observation_transcript.Missing
              | r -> r);
            e_output =
              Option.map
                (fun (b, total) ->
                  let kept = Buffer.contents b in
                  if !total > String.length kept then
                    Observation_transcript.Truncated { total = !total; prefix = kept }
                  else Observation_transcript.Data kept)
                s.output;
          })
        t.steps;
    ending = (match t.bounded with Some b -> Bounded b | None -> Exit exit_status);
  }

let framed buf keyword payload =
  Buffer.add_string buf (Printf.sprintf "%s bytes=%d\n" keyword (String.length payload));
  Buffer.add_string buf payload;
  Buffer.add_char buf '\n'

let add_field buf prefix (field : Observation_transcript.field) =
  match field with
  | Data s -> framed buf (prefix ^ " data") s
  | Truncated { total; prefix = p } ->
      framed buf (Printf.sprintf "%s truncated total=%d" prefix total) p
  | Unsupported kind ->
      Buffer.add_string buf (Printf.sprintf "%s unsupported kind=%s\n" prefix kind)
  | Failure code -> Buffer.add_string buf (Printf.sprintf "%s failure code=%s\n" prefix code)
  | Missing -> Buffer.add_string buf (prefix ^ " missing\n")
  | Unfinished -> Buffer.add_string buf (prefix ^ " unfinished\n")

let serialize log =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf (Printf.sprintf "jacquard-exploration-log format=%d\n" format_version);
  Buffer.add_string buf (log.program ^ "\n");
  Buffer.add_string buf (Printf.sprintf "seed %d\n" log.seed);
  framed buf "grants" log.grants;
  Buffer.add_string buf
    (Printf.sprintf "policy %s record-output=%s\n" (Hash.to_hex log.policy_identity)
       (if log.output_recorded then "yes" else "no"));
  List.iter
    (fun e ->
      Buffer.add_string buf
        (Printf.sprintf "step index=%d kind=%s operation=%s arguments=%d\n" e.e_index
           (kind_name e.e_kind) (Hash.to_hex e.e_operation) (List.length e.e_arguments));
      framed buf "name" e.e_name;
      (match e.e_site with
      | Some s -> framed buf "site" s
      | None -> Buffer.add_string buf "site unknown\n");
      List.iter (fun (i, f) -> add_field buf (Printf.sprintf "argument index=%d" i) f) e.e_arguments;
      Option.iter (add_field buf "result") e.e_result;
      Option.iter (add_field buf "output") e.e_output)
    log.entries;
  Buffer.add_string buf
    (match log.ending with
    | Bounded bound -> Printf.sprintf "end steps=%d bounded=%s\n" (List.length log.entries) bound
    | Exit status -> Printf.sprintf "end steps=%d exit=%d\n" (List.length log.entries) status);
  Buffer.contents buf

(* --- strict parsing: exactly the canonical bytes [serialize] writes --- *)

exception Malformed of string

let parse bytes =
  let n = String.length bytes in
  let pos = ref 0 in
  let fail fmt = Printf.ksprintf (fun m -> raise (Malformed m)) fmt in
  let line () =
    if !pos >= n then fail "unexpected end at byte %d" !pos;
    match String.index_from_opt bytes !pos '\n' with
    | None -> fail "unterminated line at byte %d" !pos
    | Some j ->
        let l = String.sub bytes !pos (j - !pos) in
        pos := j + 1;
        l
  in
  let peek () =
    match String.index_from_opt bytes !pos '\n' with
    | Some j when !pos < n -> Some (String.sub bytes !pos (j - !pos))
    | _ -> None
  in
  let payload len =
    if len < 0 || len > n - !pos - 1 || bytes.[!pos + len] <> '\n' then fail "bad framed payload";
    let p = String.sub bytes !pos len in
    pos := !pos + len + 1;
    p
  in
  let int_of s =
    match int_of_string_opt s with
    | Some i when string_of_int i = s -> i
    | _ -> fail "bad number %S" s
  in
  let hash_of s =
    match Hash.of_hex s with Some h when Hash.to_hex h = s -> h | _ -> fail "bad hash %S" s
  in
  let after prefix l =
    if String.starts_with ~prefix l then
      String.sub l (String.length prefix) (String.length l - String.length prefix)
    else fail "expected %S, found %S" prefix l
  in
  let framed_after prefix = payload (int_of (after (prefix ^ " bytes=") (line ()))) in
  let field_after prefix =
    let l = line () in
    let rest = after (prefix ^ " ") l in
    match String.split_on_char ' ' rest with
    | [ "missing" ] -> Observation_transcript.Missing
    | [ "unfinished" ] -> Unfinished
    | [ "unsupported"; k ] -> Unsupported (after "kind=" k)
    | [ "failure"; c ] -> Failure (after "code=" c)
    | [ "data"; b ] -> Data (payload (int_of (after "bytes=" b)))
    | [ "truncated"; t; b ] ->
        let total = int_of (after "total=" t) in
        let prefix = payload (int_of (after "bytes=" b)) in
        if total <= String.length prefix then fail "truncated total %d is not past its prefix" total;
        Truncated { total; prefix }
    | _ -> fail "bad field %S" l
  in
  try
    if line () <> Printf.sprintf "jacquard-exploration-log format=%d" format_version then
      fail "unsupported header";
    let hex64 x =
      String.length x = 64
      && match Hash.of_hex x with Some h -> String.equal (Hash.to_hex h) x | None -> false
    in
    let program = line () in
    (match String.split_on_char ' ' program with
    | [ "program"; src; core; prelude; "engine=interpreter" ] ->
        if not (hex64 (after "source=" src)) then fail "bad program source";
        if after "core=" core = "" then fail "bad core version";
        let p = after "prelude=" prelude in
        if not (p = "none" || hex64 p) then fail "bad prelude identity"
    | _ -> fail "bad program line");
    let seed = int_of (after "seed " (line ())) in
    let grants = framed_after "grants" in
    let policy_identity, output_recorded =
      match String.split_on_char ' ' (after "policy " (line ())) with
      | [ h; "record-output=yes" ] -> (hash_of h, true)
      | [ h; "record-output=no" ] -> (hash_of h, false)
      | _ -> fail "bad policy line"
    in
    let rec steps acc =
      match peek () with
      | Some l when String.starts_with ~prefix:"step " l ->
          let l = line () in
          let index, kind, operation, count =
            match String.split_on_char ' ' l with
            | [ "step"; i; k; o; a ] ->
                ( int_of (after "index=" i),
                  (match after "kind=" k with
                  | "operation" -> Operation_step
                  | "choice" -> Choice_step
                  | "observe" -> Observe_step
                  | other -> fail "bad kind %S" other),
                  hash_of (after "operation=" o),
                  match int_of (after "arguments=" a) with
                  | c when c >= 0 -> c
                  | c -> fail "bad argument count %d" c )
            | _ -> fail "bad step line %S" l
          in
          if index <> List.length acc then fail "step %d out of order" index;
          let name = framed_after "name" in
          let site =
            match peek () with
            | Some "site unknown" ->
                ignore (line ());
                None
            | _ -> Some (framed_after "site")
          in
          let arguments =
            List.init count (fun _ ->
                match peek () with
                | Some l when String.starts_with ~prefix:"argument index=" l ->
                    let i =
                      match String.split_on_char ' ' l with
                      | _ :: idx :: _ -> (
                          match int_of (after "index=" idx) with
                          | i when i >= 0 -> i
                          | i -> fail "bad argument index %d" i)
                      | _ -> fail "bad argument line"
                    in
                    (i, field_after (Printf.sprintf "argument index=%d" i))
                | _ -> fail "missing argument")
          in
          let result =
            match peek () with
            | Some l when String.starts_with ~prefix:"result " l -> Some (field_after "result")
            | _ -> None
          in
          let output =
            match peek () with
            | Some l when String.starts_with ~prefix:"output " l -> Some (field_after "output")
            | _ -> None
          in
          steps
            ({
               e_index = index;
               e_kind = kind;
               e_operation = operation;
               e_name = name;
               e_site = site;
               e_arguments = arguments;
               e_result = result;
               e_output = output;
             }
            :: acc)
      | _ -> List.rev acc
    in
    let entries = steps [] in
    let ending =
      match String.split_on_char ' ' (line ()) with
      | [ "end"; s; e ] -> (
          if int_of (after "steps=" s) <> List.length entries then fail "step count mismatch";
          if String.starts_with ~prefix:"exit=" e then Exit (int_of (after "exit=" e))
          else
            match after "bounded=" e with
            | ("steps" | "bytes") as b -> Bounded b
            | other -> fail "bad bound %S" other)
      | _ -> fail "bad end line"
    in
    if !pos <> n then fail "trailing bytes";
    let log = { program; seed; grants; policy_identity; output_recorded; entries; ending } in
    if not (String.equal (serialize log) bytes) then fail "not canonical";
    Ok log
  with
  | Malformed message -> Error message
  | Invalid_argument message | Failure message -> Error message

(* the log path is reserved before the run (created empty, exclusively, owner-only) and the
   recording writes through that same descriptor afterwards, so nothing at the path can be
   substituted in between *)
type reservation = Unix.file_descr

let reserve ~path =
  match Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600 with
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Error (path ^ " already exists")
  | exception Unix.Unix_error (error, _, _) -> Error (path ^ ": " ^ Unix.error_message error)
  | fd -> Ok fd

let write_reserved fd contents =
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      let bytes = Bytes.unsafe_of_string contents in
      let rec go off =
        if off < Bytes.length bytes then
          go (off + Unix.write fd bytes off (Bytes.length bytes - off))
      in
      match
        go 0;
        Unix.fsync fd
      with
      | () -> Ok ()
      | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error))

let release fd = try Unix.close fd with Unix.Unix_error _ -> ()
