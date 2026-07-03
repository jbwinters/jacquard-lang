(** Diagnostics carried by every fallible library function.

    Library code returns [('a, Diag.t list) result]; exceptions are reserved for internal invariant
    violations and are prefixed [Bug_]. Codes are short stable strings like ["E0001"] (errors) or
    ["W0001"] (warnings) that tests and docs key on; once released a code is never reused or
    renumbered. *)

type severity = Error | Warning | Info

type t = {
  severity : severity;
  span : Span.t option;
  code : string;  (** stable identifier, e.g. ["E0001"] *)
  message : string;
  hint : string option;
}

(** [make ~severity ~code msg] builds a diagnostic; [span] and [hint] are optional. Never fails. *)
let make ?span ?hint ~severity ~code message = { severity; span; code; message; hint }

(** [error ~code msg] is [make ~severity:Error]. *)
let error ?span ?hint ~code message = make ?span ?hint ~severity:Error ~code message

(** [warning ~code msg] is [make ~severity:Warning]. *)
let warning ?span ?hint ~code message = make ?span ?hint ~severity:Warning ~code message

(** [info ~code msg] is [make ~severity:Info]. *)
let info ?span ?hint ~code message = make ?span ?hint ~severity:Info ~code message

(** Lowercase severity keyword as rendered in output: ["error"], ["warning"], ["info"]. *)
let severity_to_string = function Error -> "error" | Warning -> "warning" | Info -> "info"

(** One-line rendering: [FILE:SPAN: severity[CODE]: message], with an indented hint line when a hint
    is present. The exact shape is golden-tested; change it deliberately. *)
let to_string { severity; span; code; message; hint } =
  let where = match span with Some s -> Span.to_string s ^ ": " | None -> "" in
  let hint = match hint with Some h -> "\n  hint: " ^ h | None -> "" in
  Printf.sprintf "%s%s[%s]: %s%s" where (severity_to_string severity) code message hint

let pp fmt t = Format.pp_print_string fmt (to_string t)
