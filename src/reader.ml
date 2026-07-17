(** Bootstrap `.jqd` reader (plan W1.2): s-expression-encoded triples.

    Notation, pinned:
    {v
    form := ( head arg* )
    head := lowercase symbol: [a-z][a-z0-9-]*
    arg  := form | integer | real | "text" | symbol | 'symbol | #hexhash
    v}

    Symbols in argument position may be written bare (as the plan's own examples do) or with a
    leading quote; both read as [Form.Sym]. Reals accept [+inf.0], [-inf.0], and [+nan.0]. Comments
    run from [;] to end of line and are skipped (trivia capture is W5.1). Meta is never written in
    source; the reader fills [span] from lexer positions (1-based line and byte column; end
    exclusive).

    Argument groups: the plan's examples write bare parenthesized lists in argument position —
    [(lam ((pvar n)) ...)] for a parameter list, [()] for an absent annotation. A [( ... )] whose
    first token is [(] or [)] reads as a group: a form with the reserved head ["group"] whose
    elements must themselves be forms. The printer renders a ["group"] head back as bare parens, so
    groups round-trip. ["group"] is therefore reserved and is not a kernel constructor.

    All entry points return [('a, Diag.t list) result] and stop at the first error. Text is UTF-8
    passed through byte-for-byte, no normalization (decision D3).

    Numeric edge cases, deliberate: leading zeros are accepted ([007] reads as [7]); real literals
    that overflow read as infinities ([1e400] is [+inf.0]) and underflow to [0.0]; integer literals
    outside the native 63-bit range are rejected (E0109, decision D2).

    Codes: E0101 unexpected character, E0102 unterminated text, E0103 invalid escape, E0104 invalid
    hash literal, E0105 malformed number, E0106 unexpected end of input, E0107 bad form head, E0108
    unexpected `)`, E0109 integer out of range, E0110 non-form group element, E0111 invalid quoted
    symbol, E0112 invalid bare symbol, E0113 non-form at top level, E0114 more than one form where
    one was expected, E0115 excessive structural nesting. *)

type state = {
  src : string;
  file : string;
  mutable off : int;
  mutable line : int;
  mutable col : int;
  mutable nesting_depth : int;
  mutable pending_comments : string list; (* reverse order; drained by the next form *)
}

(* Internal control flow only; never escapes this module. *)
exception Err of Diag.t

(** Maximum active form nodes accepted by the bootstrap reader. *)
let max_nesting_depth = 10_000

let error st ~code ?hint msg ~start_pos =
  let span =
    Span.make ~file:st.file ~start_pos
      ~end_pos:{ Span.line = st.line; col = st.col; offset = st.off }
  in
  raise (Err (Diag.error ~span ?hint ~code msg))

let pos st = { Span.line = st.line; col = st.col; offset = st.off }
let peek st = if st.off < String.length st.src then Some st.src.[st.off] else None

let advance st =
  (match st.src.[st.off] with
  | '\n' ->
      st.line <- st.line + 1;
      st.col <- 1
  | _ -> st.col <- st.col + 1);
  st.off <- st.off + 1

let rec skip_ws st =
  match peek st with
  | Some (' ' | '\t' | '\r' | '\n') ->
      advance st;
      skip_ws st
  | Some ';' ->
      let start = st.off in
      let rec to_eol () =
        match peek st with
        | Some '\n' | None -> ()
        | Some _ ->
            advance st;
            to_eol ()
      in
      to_eol ();
      (* full-fidelity: comments ride in trivia meta (Roslyn lesson, spec §3); they are
         captured here and attached to the NEXT form read *)
      st.pending_comments <- String.sub st.src start (st.off - start) :: st.pending_comments;
      skip_ws st
  | _ -> ()

(* Same-line trailing comment after a form: `(lit 1) ; note` attaches to that form. *)
let capture_trailing st =
  let rec skip_spaces () =
    match peek st with
    | Some (' ' | '\t') ->
        advance st;
        skip_spaces ()
    | _ -> ()
  in
  let save_off = st.off and save_line = st.line and save_col = st.col in
  skip_spaces ();
  match peek st with
  | Some ';' ->
      let start = st.off in
      let rec to_eol () =
        match peek st with
        | Some '\n' | None -> ()
        | Some _ ->
            advance st;
            to_eol ()
      in
      to_eol ();
      Some (String.sub st.src start (st.off - start))
  | _ ->
      st.off <- save_off;
      st.line <- save_line;
      st.col <- save_col;
      None

let is_sym_start c = c >= 'a' && c <= 'z'
let is_sym_char c = is_sym_start c || (c >= '0' && c <= '9') || c = '-'
let is_digit c = c >= '0' && c <= '9'

(* Library-name grammar (SL.1): one or more dot-separated segments, each
   [a-z][a-z0-9-]*, with at most one trailing ? or ! on the final segment.
   Kernel form HEADS deliberately keep the old single-segment grammar. *)
let valid_library_symbol s =
  let n = String.length s in
  if n = 0 then false
  else
    let body_end = match s.[n - 1] with '?' | '!' -> n - 1 | _ -> n in
    if body_end = 0 then false
    else
      let segments = String.split_on_char '.' (String.sub s 0 body_end) in
      List.for_all
        (fun seg -> String.length seg > 0 && is_sym_start seg.[0] && String.for_all is_sym_char seg)
        segments

let is_atom_char c =
  (* anything that is not whitespace, a delimiter, or a comment starter *)
  match c with
  | ' ' | '\t' | '\r' | '\n' | '(' | ')' | '"' | ';' | '\'' -> false
  | _ -> true

(* Read a maximal atom starting at the current offset. *)
let read_atom st =
  let start = st.off in
  let rec go () =
    match peek st with
    | Some c when is_atom_char c ->
        advance st;
        go ()
    | _ -> ()
  in
  go ();
  String.sub st.src start (st.off - start)

let valid_symbol = valid_library_symbol
let valid_head s = String.length s > 0 && is_sym_start s.[0] && String.for_all is_sym_char s

(* [+-]?digits, or a real: digits with '.' and/or exponent, or +inf.0 etc. The pure core is
   shared with the text builtins (SL.5) so text.to-int/to-real accept exactly the reader's
   literal grammar rather than growing a second parser. *)
type literal_class = LInt of int | LReal of float | LNotNumber | LBadReal | LIntOverflow

let classify_literal_class s : literal_class =
  match s with
  | "+inf.0" -> LReal infinity
  | "-inf.0" -> LReal neg_infinity
  | "+nan.0" | "-nan.0" -> LReal nan
  | "" -> LNotNumber
  | _ -> (
      let body = match s.[0] with '+' | '-' -> String.sub s 1 (String.length s - 1) | _ -> s in
      if body = "" then LNotNumber
      else
        let is_real = String.exists (fun c -> c = '.' || c = 'e' || c = 'E') body in
        let shape_ok =
          (* digits [ '.' digits ] [ ('e'|'E') ['+'|'-'] digits ] *)
          let n = String.length body in
          let i = ref 0 in
          let digits () =
            let d0 = !i in
            while !i < n && is_digit body.[!i] do
              incr i
            done;
            !i > d0
          in
          let ok = ref (digits ()) in
          if !ok && !i < n && body.[!i] = '.' then begin
            incr i;
            (* trailing digits after '.' optional: "1." reads as 1.0 *)
            ignore (digits ())
          end;
          if !ok && !i < n && (body.[!i] = 'e' || body.[!i] = 'E') then begin
            incr i;
            if !i < n && (body.[!i] = '+' || body.[!i] = '-') then incr i;
            ok := digits ()
          end;
          !ok && !i = n
        in
        if not shape_ok then LNotNumber
        else if is_real then match float_of_string_opt s with Some r -> LReal r | None -> LBadReal
        else match int_of_string_opt s with Some i -> LInt i | None -> LIntOverflow)

(** [classify_literal s] classifies [s] exactly as the reader classifies an unquoted numeric atom:
    [Some (Form.Int _ | Form.Real _)] for the reader's number spellings, [None] for everything else
    (bad shape, malformed real, int overflow). *)
let classify_literal s =
  match classify_literal_class s with
  | LInt i -> Some (Form.Int i)
  | LReal r -> Some (Form.Real r)
  | LNotNumber | LBadReal | LIntOverflow -> None

let classify_number st ~start_pos s =
  match classify_literal_class s with
  | LInt i -> Some (Form.Int i)
  | LReal r -> Some (Form.Real r)
  | LNotNumber -> None
  | LBadReal -> error st ~code:"E0105" ~start_pos (Printf.sprintf "malformed real literal %S" s)
  | LIntOverflow ->
      error st ~code:"E0109" ~start_pos
        (Printf.sprintf "integer literal %s does not fit in a native int" s)
        ~hint:"Jacquard integers are 63-bit native ints (decision D2)"

let read_text st =
  let start_pos = pos st in
  advance st (* opening quote *);
  let buf = Buffer.create 16 in
  let rec go () =
    match peek st with
    | None -> error st ~code:"E0102" ~start_pos "unterminated text literal"
    | Some '"' ->
        advance st;
        Buffer.contents buf
    | Some '\\' -> (
        let esc_start = pos st in
        advance st;
        match peek st with
        | None -> error st ~code:"E0102" ~start_pos "unterminated text literal"
        | Some 'n' ->
            advance st;
            Buffer.add_char buf '\n';
            go ()
        | Some 't' ->
            advance st;
            Buffer.add_char buf '\t';
            go ()
        | Some 'r' ->
            advance st;
            Buffer.add_char buf '\r';
            go ()
        | Some '\\' ->
            advance st;
            Buffer.add_char buf '\\';
            go ()
        | Some '"' ->
            advance st;
            Buffer.add_char buf '"';
            go ()
        | Some 'x' ->
            advance st;
            let hex_digit () =
              match peek st with
              | Some c when is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') ->
                  advance st;
                  let v =
                    match c with
                    | '0' .. '9' -> Char.code c - Char.code '0'
                    | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
                    | _ -> Char.code c - Char.code 'A' + 10
                  in
                  v
              | _ ->
                  error st ~code:"E0103" ~start_pos:esc_start
                    "invalid \\x escape: expected two hex digits"
            in
            let hi = hex_digit () in
            let lo = hex_digit () in
            Buffer.add_char buf (Char.chr ((hi * 16) + lo));
            go ()
        | Some c ->
            error st ~code:"E0103" ~start_pos:esc_start
              (Printf.sprintf "invalid escape sequence \\%c" c)
              ~hint:"valid escapes: \\\\ \\\" \\n \\t \\r \\xHH")
    | Some c ->
        advance st;
        Buffer.add_char buf c;
        go ()
  in
  go ()

let rec read_form st : Form.t =
  if st.nesting_depth >= max_nesting_depth then
    error st ~code:"E0115" ~start_pos:(pos st)
      (Printf.sprintf "bootstrap form nesting exceeds the limit of %d" max_nesting_depth);
  st.nesting_depth <- st.nesting_depth + 1;
  match read_form_body st with
  | form ->
      st.nesting_depth <- st.nesting_depth - 1;
      form
  | exception exn ->
      st.nesting_depth <- st.nesting_depth - 1;
      raise exn

and read_form_body st : Form.t =
  (* leading comments captured since the previous form belong to this one *)
  let leading = List.rev st.pending_comments in
  st.pending_comments <- [];
  let start_pos = pos st in
  advance st (* '(' *);
  skip_ws st;
  (* head, or a bare group when the next token is `(` or `)` *)
  let head =
    match peek st with
    | Some '(' | Some ')' -> "group"
    | Some c when is_sym_start c -> read_atom st
    | Some c ->
        error st ~code:"E0107" ~start_pos:(pos st)
          (Printf.sprintf "expected a form head symbol, found %C" c)
    | None -> error st ~code:"E0106" ~start_pos "unexpected end of input inside a form"
  in
  if not (valid_head head) then
    error st ~code:"E0107" ~start_pos
      (Printf.sprintf "invalid head symbol %S" head)
      ~hint:"heads are lowercase: [a-z][a-z0-9-]*";
  let rec args acc =
    skip_ws st;
    match peek st with
    | None -> error st ~code:"E0106" ~start_pos "unclosed form: expected `)`"
    | Some ')' ->
        advance st;
        List.rev acc
    | Some _ -> (
        match read_arg st with
        | Form.F sub -> (
            (* a same-line comment after a nested form is its trailing trivia *)
            match capture_trailing st with
            | Some c ->
                args
                  (Form.F
                     {
                       sub with
                       Form.meta = Meta.add Meta.key_trivia_trailing (Meta.Text c) sub.Form.meta;
                     }
                  :: acc)
            | None -> args (Form.F sub :: acc))
        | a -> args (a :: acc))
  in
  let args = args [] in
  (* comments between the last argument and `)` stay inside this form *)
  let inner_trailing = List.rev st.pending_comments in
  st.pending_comments <- [];
  let span = Span.make ~file:st.file ~start_pos ~end_pos:(pos st) in
  if head = "group" && not (List.for_all (function Form.F _ -> true | _ -> false) args) then
    error st ~code:"E0110" ~start_pos "group elements must be forms"
      ~hint:"a bare ( ... ) argument list may only contain forms";
  let meta = Meta.with_span span Meta.empty in
  let meta =
    match leading with
    | [] -> meta
    | cs -> Meta.add Meta.key_trivia (Meta.List (List.map (fun c -> Meta.Text c) cs)) meta
  in
  let meta =
    match inner_trailing with
    | [] -> meta
    | cs -> Meta.add Meta.key_trivia_inner (Meta.List (List.map (fun c -> Meta.Text c) cs)) meta
  in
  Form.form ~meta head args

and read_arg st : Form.arg =
  let start_pos = pos st in
  match peek st with
  | Some '(' -> Form.F (read_form st)
  | Some '"' -> Form.Text (read_text st)
  | Some '\'' ->
      advance st;
      let s = read_atom st in
      if valid_symbol s then Form.Sym s
      else error st ~code:"E0111" ~start_pos (Printf.sprintf "invalid quoted symbol '%s" s)
  | Some '#' -> (
      advance st;
      let s = read_atom st in
      match Hash.of_hex s with
      | Some h -> Form.Hash h
      | None ->
          error st ~code:"E0104" ~start_pos
            (Printf.sprintf "invalid hash literal #%s" s)
            ~hint:(Printf.sprintf "a hash is %d lowercase hex characters" (2 * Hash.digest_size)))
  | Some c when is_digit c || c = '+' || c = '-' -> (
      let s = read_atom st in
      match classify_number st ~start_pos s with
      | Some a -> a
      | None -> error st ~code:"E0105" ~start_pos (Printf.sprintf "malformed number %S" s))
  | Some c when is_sym_start c ->
      let s = read_atom st in
      if valid_symbol s then Form.Sym s
      else error st ~code:"E0112" ~start_pos (Printf.sprintf "invalid symbol %S" s)
  | Some ')' ->
      (* unreachable from read_form's loop; kept for safety *)
      error st ~code:"E0108" ~start_pos "unexpected `)`"
  | Some c -> error st ~code:"E0101" ~start_pos (Printf.sprintf "unexpected character %C" c)
  | None -> error st ~code:"E0106" ~start_pos "unexpected end of input"

(** [parse_string ~file s] reads every top-level form in [s]. Top level admits only forms, not
    scalars. Stops at the first error. *)
let parse_string ~file s : (Form.t list, Diag.t list) result =
  let st =
    { src = s; file; off = 0; line = 1; col = 1; nesting_depth = 0; pending_comments = [] }
  in
  let rec go acc =
    skip_ws st;
    match peek st with
    | None -> (
        (* comments after the last form attach to it as end-of-file trivia so the
           formatter can keep them (review finding: they were silently dropped) *)
        match (List.rev st.pending_comments, acc) with
        | [], _ | _, [] -> List.rev acc
        | cs, last :: earlier ->
            st.pending_comments <- [];
            List.rev
              ({
                 last with
                 Form.meta =
                   Meta.add Meta.key_trivia_eof
                     (Meta.List (List.map (fun c -> Meta.Text c) cs))
                     last.Form.meta;
               }
              :: earlier))
    | Some '(' ->
        let f = read_form st in
        let f =
          match capture_trailing st with
          | Some c ->
              { f with Form.meta = Meta.add Meta.key_trivia_trailing (Meta.Text c) f.Form.meta }
          | None -> f
        in
        go (f :: acc)
    | Some ')' ->
        let p = pos st in
        advance st;
        error st ~code:"E0108" ~start_pos:p "unexpected `)` at top level"
    | Some _ ->
        let p = pos st in
        let s = read_atom st in
        let shown = if s = "" then String.make 1 (Option.get (peek st)) else s in
        error st ~code:"E0113" ~start_pos:p
          (Printf.sprintf "expected a form at top level, found %S" shown)
  in
  match go [] with forms -> Ok forms | exception Err d -> Error [ d ]

(** [parse_one ~file s] expects exactly one top-level form. *)
let parse_one ~file s : (Form.t, Diag.t list) result =
  match parse_string ~file s with
  | Error ds -> Error ds
  | Ok [ f ] -> Ok f
  | Ok [] -> Error [ Diag.error ~code:"E0106" "expected a form, found end of input" ]
  | Ok (_ :: _ :: _) -> Error [ Diag.error ~code:"E0114" "expected exactly one top-level form" ]
