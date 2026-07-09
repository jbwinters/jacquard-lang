(** Shared name projection for the `.jac` surface.

    Kernel/store names remain lowercase library symbols. Surface terms and operations retain their
    lowercase spelling; types, constructors, and effects use the reversible D34 PascalCase
    projection. Names outside the reversible subset use an explicit backtick escape. Parser and
    printer must both call this module rather than growing independent casing rules. *)

type kind = Term | Op | Type | Con | Effect | Tvar | Rvar

let kind_tag = function
  | Term -> "term"
  | Op -> "op"
  | Type -> "type"
  | Con -> "con"
  | Effect -> "effect"
  | Tvar -> "tvar"
  | Rvar -> "rvar"

let reserved =
  [
    "type";
    "effect";
    "fn";
    "let";
    "rec";
    "match";
    "handle";
    "return";
    "resume";
    "quote";
    "unquote";
    "if";
    "then";
    "else";
    "as";
    "where";
    "forall";
    "jqd";
  ]

let is_reserved s = List.mem s reserved
let is_lower c = c >= 'a' && c <= 'z'
let is_upper c = c >= 'A' && c <= 'Z'
let is_digit c = c >= '0' && c <= '9'
let is_lower_body c = is_lower c || is_digit c

let valid_name_part s =
  String.split_on_char '-' s
  |> List.for_all (fun segment ->
      String.length segment > 0 && is_lower segment.[0] && String.for_all is_lower_body segment)

let valid_lower_name s =
  let n = String.length s in
  if n = 0 then false
  else
    let body_end = match s.[n - 1] with '?' | '!' -> n - 1 | _ -> n in
    if body_end = 0 then false
    else String.sub s 0 body_end |> String.split_on_char '.' |> List.for_all valid_name_part

let capitalize_part part =
  String.split_on_char '-' part
  |> List.map (fun segment ->
      String.make 1 (Char.uppercase_ascii segment.[0])
      ^ String.sub segment 1 (String.length segment - 1))
  |> String.concat ""

(** [to_pascal kernel] returns the reversible D34 projection, or [None] when the kernel name needs
    an escape (dotted, marked, repeated/trailing hyphens, or otherwise outside the ordinary surface
    subset). *)
let to_pascal kernel =
  if
    valid_lower_name kernel
    && (not (String.contains kernel '.'))
    && (not (String.ends_with ~suffix:"?" kernel))
    && not (String.ends_with ~suffix:"!" kernel)
  then Some (capitalize_part kernel)
  else None

(** [of_pascal surface] inverts [to_pascal]. Acronym runs are deterministic: [HTTPRequest] denotes
    [h-t-t-p-request]. *)
let of_pascal surface =
  let n = String.length surface in
  if n = 0 || not (is_upper surface.[0]) then None
  else
    let buf = Buffer.create (n + 4) in
    let valid = ref true in
    String.iteri
      (fun i c ->
        if is_upper c then begin
          if i > 0 then Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end
        else if is_lower c || is_digit c then Buffer.add_char buf c
        else valid := false)
      surface;
    if not !valid then None
    else
      let kernel = Buffer.contents buf in
      match to_pascal kernel with
      | Some roundtrip when roundtrip = surface -> Some kernel
      | _ -> None

let escape kind kernel = Printf.sprintf "`%s:%s`" (kind_tag kind) kernel

(** [render kind kernel] chooses ordinary surface spelling when it round-trips exactly, otherwise
    the kind-tagged escape required by printer totality. *)
let render kind kernel =
  match kind with
  | Type | Con | Effect -> ( match to_pascal kernel with Some s -> s | None -> escape kind kernel)
  | Term | Op | Tvar | Rvar ->
      if valid_lower_name kernel && not (is_reserved kernel) then kernel else escape kind kernel

(** [decode_escaped s] decodes a complete kind-tagged escape. Unknown tags, invalid kernel names,
    and malformed delimiters return [None]. *)
let decode_escaped s =
  let n = String.length s in
  if n < 4 || s.[0] <> '`' || s.[n - 1] <> '`' then None
  else
    let body = String.sub s 1 (n - 2) in
    match String.index_opt body ':' with
    | None -> None
    | Some i ->
        let tag = String.sub body 0 i in
        let kernel = String.sub body (i + 1) (String.length body - i - 1) in
        let kind =
          match tag with
          | "term" -> Some Term
          | "op" -> Some Op
          | "type" -> Some Type
          | "con" -> Some Con
          | "effect" -> Some Effect
          | "tvar" -> Some Tvar
          | "rvar" -> Some Rvar
          | _ -> None
        in
        if Reader.valid_symbol kernel then Option.map (fun k -> (k, kernel)) kind else None
