(* TYPE.1: builtins construct, recognise, call, register and type frozen prelude identities, never a
   name the store binds at run time; contracts in prelude_identity.mli. *)

let kind_word = function
  | Resolve.KTerm -> "term"
  | Resolve.KType -> "type"
  | Resolve.KCon -> "con"
  | Resolve.KOp -> "op"
  | Resolve.KEffect -> "effect"

let kind_of_word = function
  | "term" -> Some Resolve.KTerm
  | "type" -> Some Resolve.KType
  | "con" -> Some Resolve.KCon
  | "op" -> Some Resolve.KOp
  | "effect" -> Some Resolve.KEffect
  | _ -> None

let binding_lines store =
  List.map
    (fun (name, (e : Resolve.entry)) ->
      Printf.sprintf "%s %s %s" name (kind_word e.kind) (Hash.to_hex e.hash))
    (Store.names store)
  |> List.sort_uniq String.compare

let table : (string * Resolve.nkind, Hash.t) Hashtbl.t =
  let table = Hashtbl.create 1024 in
  List.iter
    (fun (name, word, hex) ->
      match (kind_of_word word, Hash.of_hex hex) with
      | Some kind, Some hash -> Hashtbl.replace table (name, kind) hash
      | _ -> invalid_arg ("Prelude_identity: malformed pin for " ^ name))
    Prelude_pins.pins;
  table

(* [Store.visible] remembers a confirmed pin until the store hides or removes an object, so the
   check is cheap on the per-operation paths that use it *)
(* A pinned name never falls back to the store's binding: if the pinned identity is absent (a stale
   golden after a prelude change, or a store that rebinds the name), the builtin is unavailable
   rather than resolved by name. Only names the prelude does not define fall back. *)
let lookup_kind store name kind =
  match Hashtbl.find_opt table (name, kind) with
  | Some hash when Store.visible store hash -> Some { Resolve.hash; kind }
  | Some _ -> None
  | None -> Store.lookup_kind store name kind

let pinned store name kind =
  match Hashtbl.find_opt table (name, kind) with
  | Some hash when Store.visible store hash -> Some hash
  | _ -> None
