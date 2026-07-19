(** Structured diagnostics carried by every fallible library function.

    Library code returns [('a, Diag.t list) result]; exceptions are reserved for internal invariant
    violations and are prefixed [Bug_]. A diagnostic keeps its human explanation as typed fields so
    text and machine renderers cannot disagree about their meaning or order. *)

type severity = Error | Warning | Info

type domain =
  | Process
  | Reader
  | Kernel
  | Resolution
  | Canonicalization
  | Store
  | Prelude
  | Checker
  | Runtime
  | Inference
  | Warp
  | Surface
  | Native
  | Export
  | Audit
  | Governance
  | Concurrency
  | Cli

type contrast = { mistaken : string; intended : string }

type t = {
  domain : domain;
  severity : severity;
  span : Span.t option;
  code : string option;
  summary : string;
  cause : string;
  next_step : string;
  contrast : contrast option;
}

exception Bug_invalid_diagnostic of string

let contains_newline value = String.contains value '\n' || String.contains value '\r'

let require_nonempty field value =
  if String.trim value = "" then
    raise (Bug_invalid_diagnostic (Printf.sprintf "%s must not be empty" field))

let require_single_line field value =
  require_nonempty field value;
  if contains_newline value then
    raise (Bug_invalid_diagnostic (Printf.sprintf "%s must be a single line" field))

let valid_code code =
  String.length code = 5
  && (code.[0] = 'E' || code.[0] = 'W' || code.[0] = 'I')
  &&
  let rec digits index =
    index = String.length code
    ||
    let char = code.[index] in
    char >= '0' && char <= '9' && digits (index + 1)
  in
  digits 1

let expected_code_prefix = function Error -> 'E' | Warning -> 'W' | Info -> 'I'

let validate_span = function
  | None -> ()
  | Some ({ Span.file; start_pos; end_pos } : Span.t) ->
      if String.equal file "" then
        raise (Bug_invalid_diagnostic "diagnostic span file must not be empty");
      let end_precedes_start =
        end_pos.line < start_pos.line
        || (end_pos.line = start_pos.line && end_pos.col < start_pos.col)
      in
      if
        start_pos.line < 1 || start_pos.col < 1 || start_pos.offset < 0 || end_pos.line < 1
        || end_pos.col < 1 || end_pos.offset < start_pos.offset || end_precedes_start
      then
        raise
          (Bug_invalid_diagnostic
             "diagnostic spans require one-based lines/columns, nonnegative offsets, and an \
              exclusive end at or after the start")

let validate_code ~domain ~severity = function
  | None ->
      if domain <> Runtime || severity <> Error then
        raise
          (Bug_invalid_diagnostic "only historical runtime errors may emit a code-less diagnostic")
  | Some code ->
      if not (valid_code code) then
        raise
          (Bug_invalid_diagnostic
             (Printf.sprintf "diagnostic code %S must match [EWI][0-9]{4}" code));
      let expected = expected_code_prefix severity in
      if code.[0] <> expected then
        raise
          (Bug_invalid_diagnostic
             (Printf.sprintf "diagnostic code %S does not match %s severity" code
                (match severity with Error -> "error" | Warning -> "warning" | Info -> "info")))

(** [contrast ~mistaken ~intended] records one locally plausible confusion. Both descriptions are
    required single lines; generic advice belongs in [next_step], not here. *)
let contrast ~mistaken ~intended =
  require_single_line "contrast mistaken form" mistaken;
  require_single_line "contrast intended form" intended;
  { mistaken; intended }

(** [make] is the canonical constructor. Summary and next step are deliberately single-line fields;
    a technical cause may span lines and is indented safely by the text renderer. Historically
    code-less runtime failures use [code = None] rather than receiving invented identities. *)
let make ?span ?code ~domain ~severity ~summary ~cause ~next_step ~contrast () =
  validate_code ~domain ~severity code;
  validate_span span;
  require_single_line "diagnostic summary" summary;
  require_nonempty "diagnostic cause" cause;
  require_single_line "diagnostic next step" next_step;
  Option.iter
    (fun value ->
      require_single_line "contrast mistaken form" value.mistaken;
      require_single_line "contrast intended form" value.intended)
    contrast;
  { domain; severity; span; code; summary; cause; next_step; contrast }

(** [error] builds an error diagnostic under the same validation contract as {!make}. *)
let error ?span ?code ~domain ~summary ~cause ~next_step ~contrast () =
  make ?span ?code ~domain ~severity:Error ~summary ~cause ~next_step ~contrast ()

(** [warning] builds a warning diagnostic under the same validation contract as {!make}. *)
let warning ?span ?code ~domain ~summary ~cause ~next_step ~contrast () =
  make ?span ?code ~domain ~severity:Warning ~summary ~cause ~next_step ~contrast ()

(** [info] builds an informational diagnostic under the same validation contract as {!make}. *)
let info ?span ?code ~domain ~summary ~cause ~next_step ~contrast () =
  make ?span ?code ~domain ~severity:Info ~summary ~cause ~next_step ~contrast ()

let domain t = t.domain
let severity t = t.severity
let span t = t.span
let code t = t.code
let code_or_uncoded t = Option.value ~default:"uncoded" t.code
let summary t = t.summary
let cause t = t.cause
let next_step t = t.next_step
let contrastive_hint t = t.contrast
let mistaken value = value.mistaken
let intended value = value.intended

let with_span span t =
  validate_span span;
  { t with span }

let with_cause cause t =
  require_nonempty "diagnostic cause" cause;
  { t with cause }

(** Lowercase severity keyword as rendered in output: ["error"], ["warning"], ["info"]. *)
let severity_to_string = function Error -> "error" | Warning -> "warning" | Info -> "info"

let domain_to_string = function
  | Process -> "process"
  | Reader -> "reader"
  | Kernel -> "kernel"
  | Resolution -> "resolution"
  | Canonicalization -> "canonicalization"
  | Store -> "store"
  | Prelude -> "prelude"
  | Checker -> "checker"
  | Runtime -> "runtime"
  | Inference -> "inference"
  | Warp -> "warp"
  | Surface -> "surface"
  | Native -> "native"
  | Export -> "export"
  | Audit -> "audit"
  | Governance -> "governance"
  | Concurrency -> "concurrency"
  | Cli -> "cli"

(** [json_utf8 value] preserves well-formed UTF-8 byte-for-byte and replaces each malformed input
    byte with U+FFFD. Diagnostic prose may contain arbitrary source, path, or host-error bytes, but
    the JSON v1 wire format must always remain valid UTF-8. *)
let json_utf8 value =
  let length = String.length value in
  let byte index = if index < length then Char.code value.[index] else -1 in
  let continuation index = index < length && byte index land 0xc0 = 0x80 in
  let width offset =
    let first = byte offset in
    if first < 0x80 then Some 1
    else if first >= 0xc2 && first <= 0xdf && continuation (offset + 1) then Some 2
    else if first >= 0xe0 && first <= 0xef then
      let second = byte (offset + 1) in
      let second_ok =
        if first = 0xe0 then second >= 0xa0 && second <= 0xbf
        else if first = 0xed then second >= 0x80 && second <= 0x9f
        else second >= 0x80 && second <= 0xbf
      in
      if second_ok && continuation (offset + 2) then Some 3 else None
    else if first >= 0xf0 && first <= 0xf4 then
      let second = byte (offset + 1) in
      let second_ok =
        if first = 0xf0 then second >= 0x90 && second <= 0xbf
        else if first = 0xf4 then second >= 0x80 && second <= 0x8f
        else second >= 0x80 && second <= 0xbf
      in
      if second_ok && continuation (offset + 2) && continuation (offset + 3) then Some 4 else None
    else None
  in
  let rec first_invalid offset =
    if offset >= length then None
    else match width offset with Some size -> first_invalid (offset + size) | None -> Some offset
  in
  match first_invalid 0 with
  | None -> value
  | Some invalid ->
      let buffer = Buffer.create (length + 3) in
      Buffer.add_substring buffer value 0 invalid;
      let rec repair offset =
        if offset < length then
          match width offset with
          | Some size ->
              Buffer.add_substring buffer value offset size;
              repair (offset + size)
          | None ->
              Buffer.add_string buffer "\xef\xbf\xbd";
              repair (offset + 1)
      in
      repair invalid;
      Buffer.contents buffer

(** [to_cause_string diagnostic] is the loss-aware projection used when one structured diagnostic
    explains another. It retains the child code, summary, and technical detail without importing a
    second primary action or contrast into the wrapper. *)
let to_cause_string diagnostic =
  let identity =
    match diagnostic.code with
    | Some code -> Printf.sprintf "%s: %s" code diagnostic.summary
    | None -> diagnostic.summary
  in
  Printf.sprintf "%s (%s)" identity diagnostic.cause

let render_labeled label value =
  match String.split_on_char '\n' value with
  | [] -> assert false
  | first :: rest ->
      let continuation = String.make (String.length label + 4) ' ' in
      String.concat "\n" (("  " ^ label ^ ": " ^ first) :: List.map (( ^ ) continuation) rest)

(** Canonical human rendering in semantic reading order: optional span, summary, cause, exactly one
    next step, then an applicable contrast. Spanless diagnostics begin at severity without a noisy
    placeholder. *)
let to_string t =
  let where = match t.span with Some value -> Span.to_string value ^ ": " | None -> "" in
  let identity =
    match t.code with
    | Some value -> Printf.sprintf "%s[%s]" (severity_to_string t.severity) value
    | None -> severity_to_string t.severity
  in
  let lines =
    [
      Printf.sprintf "%s%s: %s" where identity t.summary;
      render_labeled "Cause" t.cause;
      render_labeled "Next step" t.next_step;
    ]
  in
  let lines =
    match t.contrast with
    | None -> lines
    | Some value ->
        lines
        @ [
            render_labeled "Contrast"
              (Printf.sprintf "mistaken: %s; intended: %s" value.mistaken value.intended);
          ]
  in
  String.concat "\n" lines

let position_to_yojson (position : Span.pos) =
  `Assoc
    [
      ("line", `Int position.line); ("column", `Int position.col); ("offset", `Int position.offset);
    ]

let span_to_yojson (span : Span.t) =
  `Assoc
    [
      ("file", `String (json_utf8 span.file));
      ("start", position_to_yojson span.start_pos);
      ("end", position_to_yojson span.end_pos);
    ]

(** [to_yojson] exposes exactly the canonical fields under the versioned JSON v1 contract. The
    optional contrast key is absent when no specific nearby confusion applies. *)
let to_yojson t =
  let fields =
    [
      ("schema", `String "jacquard-diagnostic-v1");
      ("domain", `String (domain_to_string t.domain));
      ("code", Option.fold ~none:`Null ~some:(fun value -> `String (json_utf8 value)) t.code);
      ("severity", `String (severity_to_string t.severity));
      ("span", Option.fold ~none:`Null ~some:span_to_yojson t.span);
      ("summary", `String (json_utf8 t.summary));
      ("cause", `String (json_utf8 t.cause));
      ("next_step", `String (json_utf8 t.next_step));
    ]
  in
  let fields =
    match t.contrast with
    | None -> fields
    | Some value ->
        fields
        @ [
            ( "contrast",
              `Assoc
                [
                  ("mistaken", `String (json_utf8 value.mistaken));
                  ("intended", `String (json_utf8 value.intended));
                ] );
          ]
  in
  `Assoc fields

(** One compact JSON object suitable for JSON Lines output. *)
let to_json_string t = Yojson.Safe.to_string (to_yojson t)

let pp fmt t = Format.pp_print_string fmt (to_string t)
