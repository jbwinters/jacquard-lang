(** Content-addressed store (plan W1.6).

    On-disk layout under a root directory:
    - [objects/<decl-hash-hex>.wft] — the canonical printed form of one resolved declaration,
      written once and never modified (immutable; a re-put of an alpha-equivalent declaration keeps
      the first bytes).
    - [names.wft] — the name-to-hash index, the only mutable file. Each entry is a
      [(named <name> <kind> #<hash>)] form, kinds [term|con|op|type|effect], kept sorted.

    Derived hashes (defterm members, constructors, operations) have no object files of their own; an
    in-memory index from every known hash to its owning declaration is rebuilt by scanning
    [objects/] at {!open_store} and extended by {!put_decl}. Renames touch only [names.wft] — object
    files are byte-identical before and after (golden-tested).

    Failure modes: E0601 unknown hash, E0602 unknown name, E0603 corrupt object file, E0604
    unnameable target (a defterm group's whole hash), E0605 invalid name. *)

type role = Whole | Member of int | Constructor of int | Operation of int
type located = { decl : Kernel.decl; decl_hash : Hash.t; role : role }

type t = {
  root : string;
  mutable names : (string * Resolve.entry) list; (* sorted by name *)
  mutable index : (Hash.t * (Hash.t * role)) list; (* any hash -> owning decl hash + role *)
}

let objects_dir t = Filename.concat t.root "objects"
let names_file t = Filename.concat t.root "names.wft"
let object_path t h = Filename.concat (objects_dir t) (Hash.to_hex h ^ ".wft")
let err ~code fmt = Printf.ksprintf (fun msg -> Error [ Diag.error ~code msg ]) fmt

let kind_sym = function
  | Resolve.KTerm -> "term"
  | Resolve.KCon -> "con"
  | Resolve.KOp -> "op"
  | Resolve.KType -> "type"
  | Resolve.KEffect -> "effect"

let kind_of_sym = function
  | "term" -> Some Resolve.KTerm
  | "con" -> Some Resolve.KCon
  | "op" -> Some Resolve.KOp
  | "type" -> Some Resolve.KType
  | "effect" -> Some Resolve.KEffect
  | _ -> None

(* --- names.wft --- *)

(* Names must be printable symbols or names.wft could not round-trip through the reader.
   External entry points (bind_name, rename) validate before mutating; E0605. *)
let valid_name n =
  String.length n > 0
  && (n.[0] >= 'a' && n.[0] <= 'z')
  && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-') n

let render_names names =
  Printer.print_all
    (List.map
       (fun (n, { Resolve.hash; kind }) ->
         Form.form "named" [ Form.Sym n; Form.Sym (kind_sym kind); Form.Hash hash ])
       names)

let write_names t =
  (* render fully before opening: open_out_bin truncates, and a render failure after
     truncation would destroy the index *)
  let rendered = render_names t.names in
  let oc = open_out_bin (names_file t) in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc rendered)

let parse_names ~file src =
  match Reader.parse_string ~file src with
  | Error ds -> Error ds
  | Ok forms ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | { Form.head = "named"; args = [ Form.Sym n; Form.Sym k; Form.Hash h ]; _ } :: rest -> (
            match kind_of_sym k with
            | Some kind -> go ((n, { Resolve.hash = h; kind }) :: acc) rest
            | None -> err ~code:"E0603" "corrupt names.wft: unknown kind `%s`" k)
        | f :: _ -> err ~code:"E0603" "corrupt names.wft: unexpected `%s` form" f.Form.head
      in
      go [] forms

(* --- objects --- *)

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(* Parse, validate, and re-hash one object file; returns the decl and its hashes. *)
let load_object ~file src : (Kernel.decl * Canon.decl_hashes, Diag.t list) result =
  match Reader.parse_one ~file src with
  | Error ds -> Error ds
  | Ok form -> (
      match Kernel.decl_of_form form with
      | Error ds -> Error ds
      | Ok decl -> Result.map (fun hs -> (decl, hs)) (Canon.hash_decl decl))

let index_entries (decl : Kernel.decl) (hs : Canon.decl_hashes) =
  let derived =
    match decl.Kernel.it with
    | Kernel.DefTerm _ ->
        List.mapi (fun i (_, h) -> (h, (hs.Canon.decl_hash, Member i))) hs.Canon.named
    | Kernel.DefType _ ->
        (* named = (tname, decl_hash) :: constructors *)
        List.mapi
          (fun i (_, h) -> (h, (hs.Canon.decl_hash, if i = 0 then Whole else Constructor (i - 1))))
          hs.Canon.named
    | Kernel.DefEffect _ ->
        List.mapi
          (fun i (_, h) -> (h, (hs.Canon.decl_hash, if i = 0 then Whole else Operation (i - 1))))
          hs.Canon.named
  in
  (hs.Canon.decl_hash, (hs.Canon.decl_hash, Whole)) :: derived

(** [open_store root] opens (creating if needed) a store rooted at [root], rebuilding the hash index
    from the object files. *)
let open_store root : (t, Diag.t list) result =
  let t = { root; names = []; index = [] } in
  if not (Sys.file_exists root) then Sys.mkdir root 0o755;
  if not (Sys.file_exists (objects_dir t)) then Sys.mkdir (objects_dir t) 0o755;
  let names_res =
    if Sys.file_exists (names_file t) then
      parse_names ~file:(names_file t) (read_file (names_file t))
    else Ok []
  in
  match names_res with
  | Error ds -> Error ds
  | Ok names -> (
      t.names <- names;
      let rec scan acc = function
        | [] -> Ok acc
        | file :: rest -> (
            let path = Filename.concat (objects_dir t) file in
            match load_object ~file:path (read_file path) with
            | Error ds -> Error (Diag.error ~code:"E0603" ("corrupt object " ^ file) :: ds)
            | Ok (decl, hs) ->
                if Filename.remove_extension file <> Hash.to_hex hs.Canon.decl_hash then
                  err ~code:"E0603" "object %s does not hash to its file name" file
                else scan (index_entries decl hs @ acc) rest)
      in
      match
        scan []
          (Sys.readdir (objects_dir t)
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".wft")
          |> List.sort String.compare)
      with
      | Error ds -> Error ds
      | Ok index ->
          t.index <- index;
          Ok t)

let entry_kind (decl : Kernel.decl) = function
  | Whole -> (
      match decl.Kernel.it with
      | Kernel.DefTerm _ -> Resolve.KTerm (* unused: defterm wholes are not named *)
      | Kernel.DefType _ -> Resolve.KType
      | Kernel.DefEffect _ -> Resolve.KEffect)
  | Member _ -> Resolve.KTerm
  | Constructor _ -> Resolve.KCon
  | Operation _ -> Resolve.KOp

(** [put_decl t decl] canonicalizes, hashes, and stores a resolved declaration, then binds every
    name it introduces (members, type + constructors, effect + operations) in the name index,
    replacing existing bindings of the same names. Idempotent on the object file. *)
let put_decl t (decl : Kernel.decl) : (Canon.decl_hashes, Diag.t list) result =
  match Canon.hash_decl decl with
  | Error ds -> Error ds
  | Ok hs ->
      let path = object_path t hs.Canon.decl_hash in
      if not (Sys.file_exists path) then begin
        let oc = open_out_bin path in
        output_string oc (Printer.print_all [ Kernel.decl_to_form decl ]);
        close_out oc
      end;
      let fresh = index_entries decl hs in
      t.index <- fresh @ List.filter (fun (h, _) -> not (List.mem_assoc h fresh)) t.index;
      let new_names =
        List.filter_map
          (fun (n, h) ->
            match List.assoc_opt h fresh with
            | Some (_, role) -> Some (n, { Resolve.hash = h; kind = entry_kind decl role })
            | None -> None)
          hs.Canon.named
      in
      t.names <-
        List.sort
          (fun (a, _) (b, _) -> String.compare a b)
          (new_names @ List.filter (fun (n, _) -> not (List.mem_assoc n new_names)) t.names);
      write_names t;
      Ok hs

(** [locate t h] finds the declaration owning [h] (a decl hash or any derived hash). *)
let locate t (h : Hash.t) : (located, Diag.t list) result =
  match List.find_opt (fun (h', _) -> Hash.equal h h') t.index with
  | None -> err ~code:"E0601" "unknown hash %s" (Hash.to_hex h)
  | Some (_, (decl_hash, role)) -> (
      let path = object_path t decl_hash in
      if not (Sys.file_exists path) then
        err ~code:"E0601" "missing object file for %s" (Hash.to_hex decl_hash)
      else
        match load_object ~file:path (read_file path) with
        | Error ds -> Error ds
        | Ok (decl, _) -> Ok { decl; decl_hash; role })

(** [get t h] is [locate]'s declaration. *)
let get t h = Result.map (fun l -> l.decl) (locate t h)

(** [lookup_name t n] reads the name index. *)
let lookup_name t n = List.assoc_opt n t.names

(** All name bindings, sorted by name (the whole mutable index). *)
let names t = t.names

(** [names_view t] is the resolver's view of this store (the W1.4 seam). *)
let names_view t : Resolve.names =
  { Resolve.lookup = (fun n -> lookup_name t n); all_names = (fun () -> List.map fst t.names) }

(** [bind_name t name hash] binds [name] to a hash already known to the store. Fails on an
    unprintable name (E0605) and on a [defterm] group's whole hash (E0604) — groups are addressed
    through their members. *)
let bind_name t name hash : (unit, Diag.t list) result =
  if not (valid_name name) then
    err ~code:"E0605" "invalid name %S: names are lowercase symbols [a-z][a-z0-9-]*" name
  else
    match List.find_opt (fun (h, _) -> Hash.equal hash h) t.index with
    | None -> err ~code:"E0601" "cannot name unknown hash %s" (Hash.to_hex hash)
    | Some (_, (decl_hash, role)) -> (
        match get t decl_hash with
        | Error ds -> Error ds
        | Ok decl -> (
            match (decl.Kernel.it, role) with
            | Kernel.DefTerm _, Whole ->
                err ~code:"E0604" "cannot name a defterm group hash; name its members"
            | _ ->
                t.names <-
                  List.sort
                    (fun (a, _) (b, _) -> String.compare a b)
                    ((name, { Resolve.hash; kind = entry_kind decl role })
                    :: List.remove_assoc name t.names);
                write_names t;
                Ok ()))

(** [rename t ~old_name ~new_name] rebinds a name. Touches only [names.wft]; the new name must be a
    printable symbol (E0605). *)
let rename t ~old_name ~new_name : (unit, Diag.t list) result =
  if not (valid_name new_name) then
    err ~code:"E0605" "invalid name %S: names are lowercase symbols [a-z][a-z0-9-]*" new_name
  else
    match List.assoc_opt old_name t.names with
    | None -> err ~code:"E0602" "unknown name `%s`" old_name
    | Some entry ->
        t.names <-
          List.sort
            (fun (a, _) (b, _) -> String.compare a b)
            ((new_name, entry) :: List.remove_assoc old_name (List.remove_assoc new_name t.names));
        write_names t;
        Ok ()

(* --- dependency graph --- *)

let rec expr_refs (e : Kernel.expr) : Hash.t list =
  match e.Kernel.it with
  | Kernel.Lit _ | Kernel.Var _ | Kernel.GroupRef _ -> []
  | Kernel.Ref (h, _) -> [ h ]
  | Kernel.Lam (ps, body) -> List.concat_map pat_refs ps @ expr_refs body
  | Kernel.App (fn, args) -> expr_refs fn @ List.concat_map expr_refs args
  | Kernel.Let { binder; value; body; _ } -> pat_refs binder @ expr_refs value @ expr_refs body
  | Kernel.Match (s, cs) ->
      expr_refs s @ List.concat_map (fun c -> pat_refs c.Kernel.cpat @ expr_refs c.Kernel.cbody) cs
  | Kernel.Tuple items -> List.concat_map expr_refs items
  | Kernel.Handle { body; ret; ops } ->
      expr_refs body @ pat_refs ret.Kernel.rbinder @ expr_refs ret.Kernel.rbody
      @ List.concat_map
          (fun o ->
            (match o.Kernel.op with Kernel.Hashed h -> [ h ] | Kernel.Named _ -> [])
            @ List.concat_map pat_refs o.Kernel.params
            @ expr_refs o.Kernel.obody)
          ops
  | Kernel.Quote payload -> quoted_refs payload
  | Kernel.Unquote s -> expr_refs s
  | Kernel.Ann (s, ty) -> expr_refs s @ ty_refs ty

and quoted_refs ?(level = 0) (f : Form.t) : Hash.t list =
  if f.Form.head = "unquote" && level = 0 then
    match f.Form.args with
    | [ Form.F splice ] -> (
        match Kernel.expr_of_form splice with Ok e -> expr_refs e | Error _ -> [])
    | _ -> []
  else
    let level =
      match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    List.concat_map (function Form.F g -> quoted_refs ~level g | _ -> []) f.Form.args

and pat_refs (p : Kernel.pat) : Hash.t list =
  match p.Kernel.it with
  | Kernel.PWild | Kernel.PVar _ | Kernel.PLit _ -> []
  | Kernel.PCon (Kernel.Hashed h, ps) -> h :: List.concat_map pat_refs ps
  | Kernel.PCon (Kernel.Named _, ps) -> List.concat_map pat_refs ps
  | Kernel.PTuple ps -> List.concat_map pat_refs ps
  | Kernel.PAs (_, inner) -> pat_refs inner

and ty_refs (t : Kernel.ty) : Hash.t list =
  match t.Kernel.it with
  | Kernel.TRef (Kernel.Hashed h) -> [ h ]
  | Kernel.TRef (Kernel.Named _) | Kernel.TVar _ -> []
  | Kernel.TApp (head, args) -> ty_refs head @ List.concat_map ty_refs args
  | Kernel.TArrow (params, row, result) ->
      List.concat_map ty_refs params
      @ List.filter_map (function Kernel.Hashed h -> Some h | _ -> None) row.Kernel.effects
      @ ty_refs result
  | Kernel.TTuple items -> List.concat_map ty_refs items
  | Kernel.TForall (_, _, body) -> ty_refs body

let decl_refs (d : Kernel.decl) : Hash.t list =
  match d.Kernel.it with
  | Kernel.DefTerm bs ->
      List.concat_map
        (fun b ->
          (match b.Kernel.annot with Some ty -> ty_refs ty | None -> [])
          @ expr_refs b.Kernel.value)
        bs
  | Kernel.DefType { cons; _ } ->
      List.concat_map
        (fun c -> List.concat_map (fun f -> ty_refs f.Kernel.fty) c.Kernel.fields)
        cons
  | Kernel.DefEffect { ops; _ } ->
      List.concat_map
        (fun o -> List.concat_map ty_refs o.Kernel.op_params @ ty_refs o.Kernel.op_result)
        ops

(** [deps t h] is the deduplicated, sorted list of hashes the declaration owning [h] references. *)
let deps t h : (Hash.t list, Diag.t list) result =
  Result.map (fun l -> List.sort_uniq Hash.compare (decl_refs l.decl)) (locate t h)

(** All declaration hashes present in the store. *)
let all_decl_hashes t =
  List.sort_uniq Hash.compare
    (List.filter_map (function h, (_, Whole) -> Some h | _ -> None) t.index)
  |> List.filter (fun h ->
      (* defterm decl hashes carry role Whole via their self entry *)
      Sys.file_exists (object_path t h))

(** [dependents t h] is the computed reverse index: declaration hashes of every stored declaration
    whose {!deps} include [h]. *)
let dependents t h : (Hash.t list, Diag.t list) result =
  let rec go acc = function
    | [] -> Ok (List.sort_uniq Hash.compare acc)
    | dh :: rest -> (
        match deps t dh with
        | Error ds -> Error ds
        | Ok ds' -> go (if List.exists (Hash.equal h) ds' then dh :: acc else acc) rest)
  in
  go [] (all_decl_hashes t)
