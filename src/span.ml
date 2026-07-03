(** Source spans: a file plus a start/end position, used by diagnostics and carried in form
    metadata. Lines and columns are 1-based; [offset] is the 0-based byte offset into the source,
    kept so later phases can slice source text in O(1) for excerpts. End positions are exclusive.
    Columns count bytes, not codepoints (text is UTF-8, decision D3). *)

type pos = { line : int; col : int; offset : int }
type t = { file : string; start_pos : pos; end_pos : pos }

(** [make ~file ~start_pos ~end_pos] builds a span; no validation is performed. *)
let make ~file ~start_pos ~end_pos = { file; start_pos; end_pos }

(** A placeholder span for synthesized forms with no source location. *)
let dummy =
  {
    file = "";
    start_pos = { line = 0; col = 0; offset = 0 };
    end_pos = { line = 0; col = 0; offset = 0 };
  }

(** Structural equality on all fields. *)
let equal (a : t) (b : t) = a = b

(** [merge a b] spans from the earlier start to the later end; takes [a]'s file (callers merge spans
    from a single file). *)
let merge a b =
  let min_pos p q = if p.offset <= q.offset then p else q in
  let max_pos p q = if p.offset >= q.offset then p else q in
  {
    file = a.file;
    start_pos = min_pos a.start_pos b.start_pos;
    end_pos = max_pos a.end_pos b.end_pos;
  }

(** Renders as [file:line:col-col] on one line, [file:line:col-line:col] across lines. *)
let to_string { file; start_pos; end_pos } =
  if start_pos.line = end_pos.line then
    Printf.sprintf "%s:%d:%d-%d" file start_pos.line start_pos.col end_pos.col
  else Printf.sprintf "%s:%d:%d-%d:%d" file start_pos.line start_pos.col end_pos.line end_pos.col

let pp fmt t = Format.pp_print_string fmt (to_string t)
