(** Canonical structured diagnostics for the Jacquard library and command line. *)

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

type contrast
type t

exception Bug_invalid_diagnostic of string

val contrast : mistaken:string -> intended:string -> contrast
(** Build one specific mistaken/intended comparison. Empty or multiline descriptions raise
    {!Bug_invalid_diagnostic}. *)

val make :
  ?span:Span.t ->
  ?code:string ->
  domain:domain ->
  severity:severity ->
  summary:string ->
  cause:string ->
  next_step:string ->
  contrast:contrast option ->
  unit ->
  t
(** Canonical smart constructor. Summary and next step must be non-empty single lines; cause must be
    non-empty; codes must match [[EWI][0-9]{4}] and agree with severity. Only historical runtime
    failures may omit a code. Attached spans require a non-empty file, one-based lines and columns,
    nonnegative offsets, and an exclusive end at or after the start. Contract violations raise
    {!Bug_invalid_diagnostic}. *)

val error :
  ?span:Span.t ->
  ?code:string ->
  domain:domain ->
  summary:string ->
  cause:string ->
  next_step:string ->
  contrast:contrast option ->
  unit ->
  t

val warning :
  ?span:Span.t ->
  ?code:string ->
  domain:domain ->
  summary:string ->
  cause:string ->
  next_step:string ->
  contrast:contrast option ->
  unit ->
  t

val info :
  ?span:Span.t ->
  ?code:string ->
  domain:domain ->
  summary:string ->
  cause:string ->
  next_step:string ->
  contrast:contrast option ->
  unit ->
  t

val domain : t -> domain
val severity : t -> severity
val span : t -> Span.t option
val code : t -> string option

val code_or_uncoded : t -> string
(** [code_or_uncoded diagnostic] returns its stable code, or ["uncoded"] for the deliberately
    code-less runtime boundary. It is intended for human display and test assertions; machine
    consumers should use {!code} and preserve nullability. *)

val summary : t -> string
val cause : t -> string
val next_step : t -> string
val contrastive_hint : t -> contrast option
val mistaken : contrast -> string
val intended : contrast -> string

val with_span : Span.t option -> t -> t
(** [with_span span diagnostic] changes only the source anchor, for boundaries that deliberately
    re-anchor a stored diagnostic at its author-visible use site. *)

val with_cause : string -> t -> t
(** [with_cause cause diagnostic] replaces only the technical cause after validating that it is
    non-empty; wrappers use this to add transport context without flattening structured fields. *)

val severity_to_string : severity -> string
val domain_to_string : domain -> string

val to_cause_string : t -> string
(** Project a diagnostic into technical-cause prose for a structured wrapper. This preserves the
    child code, summary, and cause, but deliberately excludes its next step and contrast so the
    wrapper still owns exactly one primary action. *)

val to_string : t -> string
(** Render optional span/header, summary, cause, one next step, and optional contrast in that order.
*)

val to_yojson : t -> Yojson.Safe.t
(** Render the stable [jacquard-diagnostic-v1] machine structure. Well-formed UTF-8 is preserved
    byte-for-byte; every malformed input byte in a string field is replaced with U+FFFD. *)

val to_json_string : t -> string
(** Render one compact, valid-UTF-8 JSON object suitable for JSON Lines output. *)

val pp : Format.formatter -> t -> unit
