(** Form metadata: an open string-keyed map carrying fidelity, provenance, and surface hints.

    Metadata is excluded from content hashes by the metadata law (spec §3): two forms differing only
    in meta are the same definition. Reserved keys (all optional): [span], [scopes], [name],
    [trivia], [origin], [doc], and the [surface-*] parser/printer keys below. *)

module StringMap = Map.Make (String)

(** The small value language metadata entries are drawn from (spec §3). Spans get a dedicated
    constructor so the reader can attach them without encoding. *)
type value =
  | Span of Span.t
  | Sym of string
  | Text of string
  | List of value list
  | Map of (string * value) list

type t = value StringMap.t

let empty : t = StringMap.empty
let is_empty = StringMap.is_empty
let find key (t : t) = StringMap.find_opt key t
let add key value (t : t) : t = StringMap.add key value t
let remove key (t : t) : t = StringMap.remove key t
let bindings (t : t) = StringMap.bindings t

(* Reserved keys. *)
let key_span = "span"
let key_scopes = "scopes"
let key_name = "name"
let key_trivia = "trivia"
let key_trivia_trailing = "trivia-trailing"
let key_trivia_inner = "trivia-inner"
let key_trivia_eof = "trivia-eof"
let key_origin = "origin"
let key_doc = "doc"
let key_surface_form = "surface-form"
let key_surface_generated = "surface-generated"
let key_surface_hole = "surface-hole"
let key_surface_ref_kind = "surface-ref-kind"
let key_surface_reference = "surface-reference"
let key_surface_signature = "surface-signature"

(** [surface_container_key kind] is the reserved key for one named delimiter container. *)
let surface_container_key kind = "surface-container/" ^ kind

(** [value_of_meta meta] embeds a metadata map as a structured metadata value without changing key
    order or interpreting its contents. *)
let value_of_meta meta = Map (bindings meta)

(** [meta_of_value value] decodes a structured metadata map. Non-map values are not malformed
    metadata containers and therefore decode to [empty]. *)
let meta_of_value = function
  | Map fields -> List.fold_left (fun meta (key, value) -> add key value meta) empty fields
  | Span _ | Sym _ | Text _ | List _ -> empty

(** [surface_container kind t] returns the hash-excluded metadata for a named source delimiter
    container, or [empty] when the owner has no such provenance. *)
let surface_container kind t =
  match find (surface_container_key kind) t with Some value -> meta_of_value value | None -> empty

(** [with_surface_container kind container t] replaces the named source-container provenance. *)
let with_surface_container kind container t =
  let key = surface_container_key kind in
  if is_empty container then remove key t else add key (value_of_meta container) t

(** [surface_indexed_container kind index t] returns one member of an ordered metadata container.
    Indexed containers give punctuation and scalar list members stable trivia owners without
    changing the semantic AST. *)
let surface_indexed_container kind index t = surface_container (Printf.sprintf "%s/%d" kind index) t

(** [with_surface_indexed_container kind index container t] replaces one ordered metadata member.
    The caller's semantic list supplies the index domain, so no count is stored in metadata. *)
let with_surface_indexed_container kind index container t =
  with_surface_container (Printf.sprintf "%s/%d" kind index) container t

(** [without_surface_container kind t] removes only the named delimiter-container provenance. *)
let without_surface_container kind t = remove (surface_container_key kind) t

(** [signature t] returns the signature-specific metadata attached to a term binding. *)
let signature t =
  match find key_surface_signature t with Some value -> meta_of_value value | None -> empty

(** [with_signature signature_meta t] replaces signature-specific provenance, removing the key when
    [signature_meta] is empty. *)
let with_signature signature_meta t =
  if is_empty signature_meta then remove key_surface_signature t
  else add key_surface_signature (value_of_meta signature_meta) t

(** Ordered, byte-exact surface trivia. [Layout] includes whitespace and separator bytes; comments
    include their introducer but not a following newline. *)
type trivia_atom = Layout of string | Comment of string | Doc of string

(** [trivia_atom_value atom] encodes one trivia atom using the stable structured representation. *)
let trivia_atom_value = function
  | Layout text -> Map [ ("kind", Sym "layout"); ("text", Text text) ]
  | Comment text -> Map [ ("kind", Sym "comment"); ("text", Text text) ]
  | Doc text -> Map [ ("kind", Sym "doc"); ("text", Text text) ]

(** [trivia_atom_of_value value] decodes structured trivia and legacy comment text. Unknown or
    malformed values return [None] so open metadata remains forward compatible. *)
let trivia_atom_of_value = function
  | Map fields -> (
      match (List.assoc_opt "kind" fields, List.assoc_opt "text" fields) with
      | Some (Sym "layout" | Text "layout"), Some (Text text) -> Some (Layout text)
      | Some (Sym "comment" | Text "comment"), Some (Text text) -> Some (Comment text)
      | Some (Sym "doc" | Text "doc"), Some (Text text) -> Some (Doc text)
      | _ -> None)
  (* Bootstrap W5.1 stored comments directly as text. Keep that representation readable at the
     shared metadata boundary rather than teaching every consumer both encodings. *)
  | Text text -> Some (Comment text)
  | Span _ | Sym _ | List _ -> None

(** [trivia key t] decodes ordered trivia under [key]. Legacy bootstrap [Text] and [List [Text ...]]
    values are accepted as comments. Unknown values are ignored. *)
let trivia key t =
  match find key t with
  | Some (List values) -> List.filter_map trivia_atom_of_value values
  | Some value -> Option.to_list (trivia_atom_of_value value)
  | None -> []

(** [with_trivia key atoms t] replaces [key] with the stable structured trivia encoding, removing
    the key when [atoms] is empty. *)
let with_trivia key atoms t =
  match atoms with [] -> remove key t | _ -> add key (List (List.map trivia_atom_value atoms)) t

(** [append_trivia key atoms t] appends in source order to existing structured or legacy trivia. *)
let append_trivia key atoms t = with_trivia key (trivia key t @ atoms) t

(** [docs t] returns attached doc-comment atoms in source order. *)
let docs t = trivia key_doc t

(** [with_docs atoms t] replaces attached documentation atoms. *)
let with_docs atoms t = with_trivia key_doc atoms t

(** [append_docs atoms t] appends documentation atoms in source order. *)
let append_docs atoms t = with_docs (docs t @ atoms) t

(** [without_trivia t] removes all fidelity and documentation keys. Generated lowering nodes use it
    to avoid acquiring a second copy of trivia already owned by source nodes. *)
let without_trivia t =
  List.fold_left
    (fun meta key -> remove key meta)
    t
    [ key_trivia; key_trivia_trailing; key_trivia_inner; key_trivia_eof; key_doc ]

(** [merge_trivia left right] keeps ordinary metadata from [left], fills absent non-fidelity keys
    from [right], and concatenates every trivia/doc channel left-to-right. Spans are left to the
    caller because merge sites differ in whether they represent a union or one source node. *)
let merge_trivia left right =
  let merged =
    StringMap.fold
      (fun key value meta -> if StringMap.mem key meta then meta else StringMap.add key value meta)
      right left
  in
  let merge_key key meta = with_trivia key (trivia key left @ trivia key right) meta in
  let merged =
    List.fold_left
      (fun meta key -> merge_key key meta)
      merged
      [ key_trivia; key_trivia_trailing; key_trivia_inner; key_trivia_eof ]
  in
  with_docs (docs left @ docs right) merged

(** [comment_texts key t] returns comment and doc bytes, excluding layout atoms. *)
let comment_texts key t =
  trivia key t
  |> List.filter_map (function Layout _ -> None | Comment text | Doc text -> Some text)

(** [span t] reads the reserved [span] key; [None] if absent or not a span. *)
let span t = match find key_span t with Some (Span s) -> Some s | _ -> None

let with_span s t = add key_span (Span s) t

(** [name t] reads the reserved [name] key: the source name retained on a hash-resolved reference
    for display. *)
let name t = match find key_name t with Some (Sym n | Text n) -> Some n | _ -> None

let with_name n t = add key_name (Sym n) t

(** [surface_form t] is the surface construct that produced a desugared kernel node. It is
    presentation/provenance metadata and therefore excluded from canonical identity with all other
    metadata. *)
let surface_form t =
  match find key_surface_form t with Some (Sym n | Text n) -> Some n | _ -> None

let with_surface_form n t = add key_surface_form (Sym n) t

(** [surface_generated t] names the generated surface artifact represented by a kernel node, such as
    ["accessor"]. *)
let surface_generated t =
  match find key_surface_generated t with Some (Sym n | Text n) -> Some n | _ -> None

let with_surface_generated n t = add key_surface_generated (Sym n) t

(** [surface_hole t] reads the stable textual recovery-hole identifier attached by the parser. *)
let surface_hole t =
  match find key_surface_hole t with Some (Sym n | Text n) -> Some n | _ -> None

let with_surface_hole n t = add key_surface_hole (Text n) t

(** [surface_ref_kind t] is the explicit value-reference intent carried from surface syntax or a
    decoded structural quote marker to name resolution: ["term"], ["con"], or ["op"]. It is a
    hash-excluded elaboration hint, not a kernel form or part of reference identity; quoted
    constructor/operation identity is carried by the marker structure itself. *)
let surface_ref_kind t =
  match find key_surface_ref_kind t with Some (Sym n | Text n) -> Some n | _ -> None

(** [with_surface_ref_kind kind t] records an explicit surface value-reference kind. Callers use
    ["term"], ["con"], or ["op"]; unknown values are ignored by resolution. *)
let with_surface_ref_kind kind t = add key_surface_ref_kind (Sym kind) t

(** [is_surface_reference t] is true only for a bare reference authored in `.jac`. Recovery and
    diagnostics use this hash-excluded marker to distinguish source references from bootstrap
    [(var ...)] nodes without changing resolution or identity. *)
let is_surface_reference t =
  match find key_surface_reference t with Some (Sym "true" | Text "true") -> true | _ -> false

(** [with_surface_reference t] marks an authored `.jac` reference. *)
let with_surface_reference t = add key_surface_reference (Sym "true") t

let rec equal_value a b =
  match (a, b) with
  | Span a, Span b -> Span.equal a b
  | Sym a, Sym b | Text a, Text b -> String.equal a b
  | List a, List b -> List.equal equal_value a b
  | Map a, Map b ->
      List.equal (fun (ka, va) (kb, vb) -> String.equal ka kb && equal_value va vb) a b
  | (Span _ | Sym _ | Text _ | List _ | Map _), _ -> false

let equal (a : t) (b : t) = StringMap.equal equal_value a b
