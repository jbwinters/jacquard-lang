(** ET.3's single Audit chain carrier.

    The record syntax is:

    [(audit-chain-v1 #PREVIOUS #DIGEST (audit-entry-v1 ...))]

    DIGEST is HASH_V0 over the domain tag, PREVIOUS's 32 raw bytes, and the embedded entry's
    existing [Printer.print_compact] bytes. The record wrapper is transport, not a second semantic
    serializer. *)

type record = { previous : Hash.t; digest : Hash.t; entry : Form.t }

let domain = "jacquard-audit-chain-v1\000"
let genesis = Hash.of_string "jacquard-audit-chain-v1-genesis\000"
let error ~code fmt = Printf.ksprintf (fun message -> Error [ Diag.error ~code message ]) fmt
let form0 names = function { Form.head; args = []; _ } -> List.mem head names | _ -> false
let hash_form = function { Form.head = "hash"; args = [ Form.Hash _ ]; _ } -> true | _ -> false
let lit_text = function { Form.head = "lit"; args = [ Form.Text _ ]; _ } -> true | _ -> false

let confidence = function
  | {
      Form.head = "confidence-v1";
      args = [ Form.F { Form.head = "lit"; args = [ Form.Real _ ]; _ } ];
      _;
    } ->
      true
  | _ -> false

let text_list = function
  | { Form.head = "text-list-v1"; args; _ } ->
      List.for_all (function Form.F value -> lit_text value | _ -> false) args
  | _ -> false

let assessment = function
  | {
      Form.head = "assessment-v1";
      args = [ Form.F risk; Form.F conf; Form.F reasons; Form.F _evidence ];
      _;
    } ->
      form0 [ "low"; "medium"; "high"; "forbidden" ] risk && confidence conf && text_list reasons
  | _ -> false

let decision = function
  | { Form.head = "approved-v1"; args = [ Form.F proposal; Form.F approver; Form.F _evidence ]; _ }
    ->
      hash_form proposal && lit_text approver
  | { Form.head = "denied-v1"; args = [ Form.F proposal; Form.F approver; Form.F reason ]; _ } ->
      hash_form proposal && lit_text approver && lit_text reason
  | { Form.head = "escalate-v1"; args = [ Form.F proposal; Form.F reason ]; _ } ->
      hash_form proposal && lit_text reason
  | _ -> false

let outcome = function
  | { Form.head = "outcome-summary-v1"; args = [ Form.F status; Form.F digest; Form.F detail ]; _ }
    ->
      lit_text status && hash_form digest && lit_text detail
  | _ -> false

let entry_shape = function
  | {
      Form.head = "audit-entry-v1";
      args =
        [
          Form.F
            {
              Form.head = "evaluated-v1";
              args = [ Form.F call; Form.F policy; Form.F assessment_value; Form.F verdict ];
              _;
            };
        ];
      _;
    } ->
      hash_form call && hash_form policy && assessment assessment_value
      && form0 [ "allow"; "simulate"; "ask"; "block" ] verdict
  | {
      Form.head = "audit-entry-v1";
      args =
        [
          Form.F
            {
              Form.head = "consented-v1";
              args = [ Form.F call; Form.F proposal; Form.F decision_value ];
              _;
            };
        ];
      _;
    } ->
      hash_form call && hash_form proposal && decision decision_value
  | {
      Form.head = "audit-entry-v1";
      args =
        [
          Form.F
            {
              Form.head = "completed-v1";
              args = [ Form.F call; Form.F branch; Form.F outcome_value ];
              _;
            };
        ];
      _;
    } ->
      hash_form call && lit_text branch && outcome outcome_value
  | _ -> false

let entry_bytes entry =
  if not (entry_shape entry) then
    error ~code:"E1302" "malformed AuditEntry: expected the exact released audit-entry-v1 schema"
  else
    match Printer.print_compact entry with
    | bytes -> Ok bytes
    | exception Printer.Bug_unprintable message ->
        error ~code:"E1302" "malformed AuditEntry: %s" message

(** See {!Audit_chain.digest}. *)
let digest ~previous entry =
  Result.map
    (fun bytes -> Hash.of_string (domain ^ Hash.to_raw previous ^ bytes))
    (entry_bytes entry)

(** See {!Audit_chain.append}. *)
let append ~previous entry =
  Result.map (fun digest -> { previous; digest; entry }) (digest ~previous entry)

(** See {!Audit_chain.head}. *)
let head record = record.digest

let record_form record =
  Form.form "audit-chain-v1"
    [ Form.Hash record.previous; Form.Hash record.digest; Form.F record.entry ]

(** See {!Audit_chain.render}. *)
let render record = Printer.print_compact (record_form record)

let parse_record ~file ~line_number line =
  match Reader.parse_one ~file line with
  | Error diagnostics ->
      let detail =
        match diagnostics with
        | diagnostic :: _ -> diagnostic.Diag.message
        | [] -> "unknown reader failure"
      in
      error ~code:"E1301" "%s:%d: malformed Audit chain record: %s" file line_number detail
  | Ok form when not (String.equal (Printer.print_compact form) line) ->
      error ~code:"E1301" "%s:%d: Audit chain record is not in canonical one-line form" file
        line_number
  | Ok
      {
        Form.head = "audit-chain-v1";
        args = [ Form.Hash previous; Form.Hash stored; Form.F entry ];
        _;
      } ->
      Ok { previous; digest = stored; entry }
  | Ok { Form.head; _ } when not (String.equal head "audit-chain-v1") ->
      error ~code:"E1302" "%s:%d: unsupported Audit chain version `%s`" file line_number head
  | Ok _ -> error ~code:"E1301" "%s:%d: malformed audit-chain-v1 record" file line_number

let finish ~expected_head actual =
  if Hash.equal actual expected_head then Ok actual
  else
    error ~code:"E1305" "published Audit head mismatch: expected #%s, reconstructed #%s"
      (Hash.to_hex expected_head) (Hash.to_hex actual)

(** See {!Audit_chain.verify_string}. *)
let verify_string ~file ~expected_head source =
  if String.equal source "" then finish ~expected_head genesis
  else if source.[String.length source - 1] <> '\n' then
    error ~code:"E1301" "%s: Audit chain must end with LF" file
  else
    let lines = String.split_on_char '\n' source in
    let lines = List.rev (List.tl (List.rev lines)) in
    let rec verify line_number previous = function
      | [] -> finish ~expected_head previous
      | "" :: _ ->
          error ~code:"E1301" "%s:%d: blank lines are not valid Audit chain records" file
            line_number
      | line :: rest -> (
          match parse_record ~file ~line_number line with
          | Error _ as error -> error
          | Ok record -> (
              if not (Hash.equal record.previous previous) then
                error ~code:"E1303" "%s:%d: broken Audit predecessor: expected #%s, found #%s" file
                  line_number (Hash.to_hex previous) (Hash.to_hex record.previous)
              else
                match digest ~previous record.entry with
                | Error diagnostics ->
                    Error
                      (List.map
                         (fun diagnostic ->
                           {
                             diagnostic with
                             Diag.message =
                               Printf.sprintf "%s:%d: %s" file line_number diagnostic.Diag.message;
                           })
                         diagnostics)
                | Ok computed when not (Hash.equal computed record.digest) ->
                    error ~code:"E1304"
                      "%s:%d: Audit record digest mismatch: stored #%s, computed #%s" file
                      line_number (Hash.to_hex record.digest) (Hash.to_hex computed)
                | Ok computed -> verify (line_number + 1) computed rest))
    in
    verify 1 genesis lines

let max_log_bytes = 16 * 1024 * 1024
let max_entry_bytes = 1024 * 1024

let changed before after =
  before.Unix.st_dev <> after.Unix.st_dev
  || before.st_ino <> after.st_ino || before.st_kind <> after.st_kind
  || before.st_size <> after.st_size || before.st_mtime <> after.st_mtime
  || before.st_ctime <> after.st_ctime

let io_exception = function
  | Sys_error message -> Some message
  | Unix.Unix_error (code, operation, path) ->
      Some
        (if String.equal path "" then Printf.sprintf "%s: %s" operation (Unix.error_message code)
         else Printf.sprintf "%s: %s" path (Unix.error_message code))
  | End_of_file -> Some "unexpected end of file while the file was changing"
  | _ -> None

type read_snapshot = { bytes : string; stats : Unix.stats }
type append_failure = Append_io of string | Append_verify of Diag.t list

let read_descriptor_bounded ~max_bytes ~file descriptor =
  let before = Unix.fstat descriptor in
  if before.st_kind <> Unix.S_REG then Error "not a regular file"
  else if before.st_size > max_bytes then
    Error (Printf.sprintf "exceeds the %d-byte limit" max_bytes)
  else
    let bytes = Buffer.create (min before.st_size 65536) in
    let chunk = Bytes.create 65536 in
    ignore (Unix.lseek descriptor 0 Unix.SEEK_SET);
    let rec read total =
      let count = Unix.read descriptor chunk 0 (Bytes.length chunk) in
      if count = 0 then total
      else
        let total = total + count in
        if total > max_bytes then raise (Sys_error "file grew past the bounded-read limit")
        else (
          Buffer.add_subbytes bytes chunk 0 count;
          read total)
    in
    let total = read 0 in
    let after = Unix.fstat descriptor in
    let path_after = Unix.stat file in
    if changed before after || changed after path_after || total <> before.st_size then
      Error "changed while it was being read"
    else Ok { bytes = Buffer.contents bytes; stats = after }

let read_file_bounded ~what ~max_bytes file =
  match
    try
      let descriptor = Unix.openfile file [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () -> read_descriptor_bounded ~max_bytes ~file descriptor)
    with exception_ -> (
      match io_exception exception_ with Some message -> Error message | None -> raise exception_)
  with
  | Ok snapshot -> Ok snapshot.bytes
  | Error message -> error ~code:"E1306" "cannot read %s %s: %s" what file message

let read_log_file file = read_file_bounded ~what:"Audit chain" ~max_bytes:max_log_bytes file

(** See {!Audit_chain.read_entry_file}. *)
let read_entry_file ~file =
  Result.bind
    (read_file_bounded ~what:"Audit entry" ~max_bytes:max_entry_bytes file)
    (Reader.parse_one ~file)

(** See {!Audit_chain.verify_file}. *)
let verify_file ~file ~expected_head =
  Result.bind (read_log_file file) (verify_string ~file ~expected_head)

(** See {!Audit_chain.append_file}. *)
let append_file ~file ~previous entry =
  let rec open_descriptor attempts =
    if attempts = 4 then raise (Sys_error "path changed repeatedly while opening for append")
    else
      match Unix.openfile file [ Unix.O_RDWR; Unix.O_APPEND ] 0 with
      | descriptor -> descriptor
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> (
          if not (Hash.equal previous genesis) then
            raise (Sys_error "the Audit chain disappeared before append")
          else
            match
              Unix.openfile file [ Unix.O_RDWR; Unix.O_APPEND; Unix.O_CREAT; Unix.O_EXCL ] 0o600
            with
            | descriptor -> descriptor
            | exception Unix.Unix_error (Unix.EEXIST, _, _) -> open_descriptor (attempts + 1))
  in
  Result.bind (append ~previous entry) (fun record ->
      match
        try
          let descriptor = open_descriptor 0 in
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              ignore (Unix.lseek descriptor 0 Unix.SEEK_SET);
              Unix.lockf descriptor Unix.F_TLOCK 0;
              match read_descriptor_bounded ~max_bytes:max_log_bytes ~file descriptor with
              | Error message -> Error (Append_io message)
              | Ok snapshot -> (
                  match verify_string ~file ~expected_head:previous snapshot.bytes with
                  | Error diagnostics -> Error (Append_verify diagnostics)
                  | Ok _ ->
                      let descriptor_now = Unix.fstat descriptor in
                      let path_now = Unix.stat file in
                      if changed snapshot.stats descriptor_now || changed descriptor_now path_now
                      then Error (Append_io "changed after verification and before append")
                      else
                        let line = render record ^ "\n" in
                        let offset = Unix.lseek descriptor 0 Unix.SEEK_END in
                        if offset <> descriptor_now.st_size then
                          Error (Append_io "size changed after verification and before append")
                        else
                          let written =
                            Unix.write_substring descriptor line 0 (String.length line)
                          in
                          if written <> String.length line then
                            raise (Sys_error "short write while appending the Audit record")
                          else (
                            Unix.fsync descriptor;
                            Ok (head record))))
        with exception_ -> (
          match io_exception exception_ with
          | Some message -> Error (Append_io message)
          | None -> raise exception_)
      with
      | Ok head -> Ok head
      | Error (Append_verify diagnostics) -> Error diagnostics
      | Error (Append_io message) ->
          error ~code:"E1306" "cannot append Audit chain %s: %s" file message)
