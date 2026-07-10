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

(** [surface_ref_kind t] is the explicit value-reference intent carried from surface syntax to name
    resolution: ["term"], ["con"], or ["op"]. It is a hash-excluded elaboration hint, not a kernel
    form or part of reference identity. *)
let surface_ref_kind t =
  match find key_surface_ref_kind t with Some (Sym n | Text n) -> Some n | _ -> None

(** [with_surface_ref_kind kind t] records an explicit surface value-reference kind. Callers use
    ["term"], ["con"], or ["op"]; unknown values are ignored by resolution. *)
let with_surface_ref_kind kind t = add key_surface_ref_kind (Sym kind) t

let rec equal_value a b =
  match (a, b) with
  | Span a, Span b -> Span.equal a b
  | Sym a, Sym b | Text a, Text b -> String.equal a b
  | List a, List b -> List.equal equal_value a b
  | Map a, Map b ->
      List.equal (fun (ka, va) (kb, vb) -> String.equal ka kb && equal_value va vb) a b
  | (Span _ | Sym _ | Text _ | List _ | Map _), _ -> false

let equal (a : t) (b : t) = StringMap.equal equal_value a b
