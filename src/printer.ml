(** Canonical printer for bootstrap `.wft` notation (plan W1.2).

    Formatting is deterministic: a form whose arguments are all scalars prints on one line; a form
    with any form/group argument puts every argument on its own line, indented two spaces, printed
    inline (so forms occupy one line each at depth 0 and 1, deeper structure stays inline). Forms
    with the reserved head ["group"] print as bare parenthesized lists, matching how the reader
    produced them. Meta is never printed; printing then reparsing yields forms equal ignoring meta.
*)

exception Bug_unprintable of string
(** Raised (internal invariant) when a form holds a head or symbol the notation cannot represent:
    anything outside [[a-z][a-z0-9-]*]. Reader-produced forms never trip this; it guards
    programmatically built forms (e.g. [Kernel.to_form]) against silently printing output that would
    reparse to a different form. *)

let check_symbol ~what s =
  let ok =
    String.length s > 0
    && (s.[0] >= 'a' && s.[0] <= 'z')
    && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-') s
  in
  if not ok then raise (Bug_unprintable (Printf.sprintf "%s %S is not printable" what s))

let escape_text s =
  let buf = Buffer.create (String.length s + 2) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
          Buffer.add_string buf (Printf.sprintf "\\x%02x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(** Shortest decimal rendering that reparses to the identical double; non-finite reals use the
    Scheme-style [+inf.0]/[-inf.0]/[+nan.0] spellings the reader accepts. *)
let real_repr r =
  if Float.is_nan r then "+nan.0"
  else if r = infinity then "+inf.0"
  else if r = neg_infinity then "-inf.0"
  else
    let candidate =
      let s15 = Printf.sprintf "%.15g" r in
      if float_of_string s15 = r then s15
      else
        let s16 = Printf.sprintf "%.16g" r in
        if float_of_string s16 = r then s16 else Printf.sprintf "%.17g" r
    in
    if String.exists (fun c -> c = '.' || c = 'e' || c = 'E') candidate then candidate
    else candidate ^ ".0"

let scalar_to_string = function
  | Form.Int i -> string_of_int i
  | Form.Real r -> real_repr r
  | Form.Text s -> "\"" ^ escape_text s ^ "\""
  | Form.Sym s ->
      check_symbol ~what:"symbol" s;
      s
  | Form.Hash h -> "#" ^ Hash.to_hex h
  | Form.F _ -> invalid_arg "scalar_to_string: form"

let rec inline_form (f : Form.t) =
  let args = List.map inline_arg f.Form.args in
  if f.Form.head = "group" then begin
    (* a group whose first element is a scalar reparses as a headed form *)
    (match f.Form.args with
    | (Form.Int _ | Form.Real _ | Form.Text _ | Form.Sym _ | Form.Hash _) :: _ ->
        raise (Bug_unprintable "group with a leading scalar element")
    | _ -> ());
    "(" ^ String.concat " " args ^ ")"
  end
  else begin
    check_symbol ~what:"head" f.Form.head;
    "(" ^ String.concat " " (f.Form.head :: args) ^ ")"
  end

and inline_arg = function Form.F f -> inline_form f | scalar -> scalar_to_string scalar

(** [print f] renders one top-level form canonically, without a trailing newline. *)
let print (f : Form.t) =
  let has_form_arg = List.exists (function Form.F _ -> true | _ -> false) f.Form.args in
  if not has_form_arg then inline_form f
  else
    let open_line = if f.Form.head = "group" then "(" else "(" ^ f.Form.head in
    let lines = List.map (fun a -> "  " ^ inline_arg a) f.Form.args in
    open_line ^ "\n" ^ String.concat "\n" lines ^ ")"

(** [print_all forms] renders a whole `.wft` file: forms separated by a blank line, trailing
    newline. *)
let print_all (forms : Form.t list) = String.concat "\n\n" (List.map print forms) ^ "\n"
