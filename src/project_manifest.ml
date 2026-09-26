(* The local project manifest (PKG.1). See project_manifest.mli for the contract. *)

type kind = Term | Con | Op | Type | Effect
type selector = { kind : kind; name : string }
type source = Path of string | Bundle of string
type dep = { alias : string; source : source; pin : Hash.t option }
type entry_kind = Run | Test

type entry = {
  ekind : entry_kind;
  ename : string;
  eunits : string list;
  grants : string list;
  native : bool;
}

type t = {
  name : string;
  core : int * int;
  namespace : string option;
  units : string list;
  exports : selector list;
  deps : dep list;
  entries : entry list;
  metadata : (string * string) list;
}

let version = "project-v1"
let max_bytes = 64 * 1024
let max_text = 1024
let max_units = 256
let max_entries = 64
let max_exports = 1024
let max_deps = 64

let kind_name = function
  | Term -> "term"
  | Con -> "con"
  | Op -> "op"
  | Type -> "type"
  | Effect -> "effect"

let kind_of_name = function
  | "term" -> Some Term
  | "con" -> Some Con
  | "op" -> Some Op
  | "type" -> Some Type
  | "effect" -> Some Effect
  | _ -> None

let entry_kind_name = function Run -> "run" | Test -> "test"

let summary = function
  | "E1700" -> "The project manifest is malformed."
  | "E1701" -> "The project manifest has an unknown field."
  | "E1702" -> "The project manifest repeats an item that must be unique."
  | "E1703" -> "The project manifest exceeds a size budget."
  | "E1704" -> "The running Core does not satisfy the project's requirement."
  | "E1735" -> "No project manifest was found or it could not be read."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown project manifest code " ^ code))

let next_step = function
  | "E1700" -> "Correct the manifest to the project-v1 schema (docs/designs/project-structure.md)."
  | "E1701" -> "Remove the field, or move free-form information into (metadata ...)."
  | "E1702" -> "Keep one occurrence of each field, unit, selector, alias, entry, grant, and key."
  | "E1703" -> "Reduce the manifest below its budget, or split the project."
  | "E1704" -> "Use a Core release that satisfies (requires (core ...)), or update the requirement."
  | "E1735" -> "Run the command inside a project, or pass --project DIR."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown project manifest code " ^ code))

let diag ?span code cause =
  Diag.error ?span ~domain:Diag.Project ~code ~summary:(summary code) ~cause
    ~next_step:(next_step code) ~contrast:None ()

(* --- validation: every problem is collected, nothing short-circuits --- *)

type acc = { mutable errors : Diag.t list }

let report acc ?span code fmt =
  Printf.ksprintf (fun cause -> acc.errors <- diag ?span code cause :: acc.errors) fmt

let span_of (f : Form.t) = Form.span f

let text acc ~(owner : Form.t) what = function
  | Form.Text s ->
      if String.length s > max_text then begin
        report acc ?span:(span_of owner) "E1703" "%s is %d bytes; the limit is %d" what
          (String.length s) max_text;
        None
      end
      else Some s
  | _ ->
      report acc ?span:(span_of owner) "E1700" "%s must be a text literal" what;
      None

let symbol acc ~(owner : Form.t) what = function
  | Form.Sym s when String.length s <= max_text -> Some s
  | Form.Sym _ ->
      report acc ?span:(span_of owner) "E1703" "%s is longer than %d bytes" what max_text;
      None
  | _ ->
      report acc ?span:(span_of owner) "E1700" "%s must be a symbol" what;
      None

let subforms acc ~(owner : Form.t) what args =
  List.filter_map
    (function
      | Form.F f -> Some f
      | _ ->
          report acc ?span:(span_of owner) "E1700" "%s must contain only (field ...) forms" what;
          None)
    args

let check_unique acc ~(owner : Form.t) what key items =
  let seen = Hashtbl.create 16 in
  List.iter
    (fun item ->
      let k = key item in
      if Hashtbl.mem seen k then
        report acc ?span:(span_of owner) "E1702" "%s %s appears more than once" what k
      else Hashtbl.add seen k ())
    items

let check_count acc ~(owner : Form.t) what limit items =
  if List.length items > limit then
    report acc ?span:(span_of owner) "E1703" "%s has %d items; the limit is %d" what
      (List.length items) limit

let is_kebab s =
  s <> ""
  && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-') s
  && s.[0] >= 'a'
  && s.[0] <= 'z'
  && s.[String.length s - 1] <> '-'

let relative_path acc ~(owner : Form.t) what path =
  let lower = String.lowercase_ascii path in
  let has_scheme =
    match String.index_opt path ':' with
    | Some i -> i > 0 && i + 2 < String.length path && String.sub path i 3 = "://"
    | None -> false
  in
  if path = "" || path.[0] = '/' || has_scheme || String.contains path '\000' then begin
    report acc ?span:(span_of owner) "E1700" "%s %S must be a relative file path" what path;
    None
  end
  else if not (Filename.check_suffix lower ".jac" || Filename.check_suffix lower ".jqd") then begin
    report acc ?span:(span_of owner) "E1700" "%s %S must name a .jac or .jqd source file" what path;
    None
  end
  else Some path

let unit_list acc ~(owner : Form.t) what args =
  let units =
    List.filter_map
      (fun a ->
        match text acc ~owner what a with Some p -> relative_path acc ~owner what p | None -> None)
      args
  in
  check_count acc ~owner what max_units units;
  check_unique acc ~owner what Fun.id units;
  units

let parse_core acc (owner : Form.t) args =
  let parse_version s =
    match String.split_on_char '.' s with
    | [ major; minor ] -> (
        match (int_of_string_opt major, int_of_string_opt minor) with
        | Some a, Some b when a >= 0 && b >= 0 && string_of_int a = major && string_of_int b = minor
          ->
            Some (a, b)
        | _ -> None)
    | _ -> None
  in
  match subforms acc ~owner "(requires ...)" args with
  | [ ({ Form.head = "core"; args = [ v ]; _ } as core) ] -> (
      match text acc ~owner:core "the Core requirement" v with
      | Some s -> (
          match parse_version s with
          | Some version -> Some version
          | None ->
              report acc ?span:(span_of core) "E1700" "Core requirement %S must be \"MAJOR.MINOR\""
                s;
              None)
      | None -> None)
  | [ ({ Form.head; _ } as f) ] when head <> "core" ->
      report acc ?span:(span_of f) "E1701" "unknown requirement (%s ...); v1 knows only (core ...)"
        head;
      None
  | _ ->
      report acc ?span:(span_of owner) "E1700"
        "(requires ...) must be exactly (requires (core \"MAJOR.MINOR\"))";
      None

let parse_exports acc (owner : Form.t) args =
  let selectors =
    List.filter_map
      (fun (f : Form.t) ->
        match (kind_of_name f.head, f.args) with
        | Some kind, [ name ] -> (
            match symbol acc ~owner:f "an export name" name with
            | Some name -> Some { kind; name }
            | None -> None)
        | Some _, _ ->
            report acc ?span:(span_of f) "E1700" "export selector (%s ...) needs exactly one name"
              f.head;
            None
        | None, _ ->
            report acc ?span:(span_of f) "E1700"
              "unknown export kind %s; use term, con, op, type, or effect" f.head;
            None)
      (subforms acc ~owner "(exports ...)" args)
  in
  check_count acc ~owner "(exports ...)" max_exports selectors;
  check_unique acc ~owner "export" (fun s -> kind_name s.kind ^ " " ^ s.name) selectors;
  selectors

let parse_dep acc (f : Form.t) =
  if f.head <> "dep" then begin
    report acc ?span:(span_of f) "E1700" "(deps ...) contains (%s ...); expected (dep ...)" f.head;
    None
  end
  else
    let alias = ref None and source = ref None and pin = ref None in
    let fields = subforms acc ~owner:f "(dep ...)" f.args in
    check_unique acc ~owner:f "dependency field" (fun (g : Form.t) -> g.head) fields;
    List.iter
      (fun (g : Form.t) ->
        match (g.head, g.args) with
        | "as", [ a ] -> alias := symbol acc ~owner:g "a dependency alias" a
        | "path", [ p ] ->
            if !source <> None then
              report acc ?span:(span_of g) "E1702" "a dependency has more than one source"
            else source := Option.map (fun p -> Path p) (text acc ~owner:g "a dependency path" p)
        | "bundle", [ p ] ->
            if !source <> None then
              report acc ?span:(span_of g) "E1702" "a dependency has more than one source"
            else source := Option.map (fun p -> Bundle p) (text acc ~owner:g "a bundle path" p)
        | "pin", [ Form.Hash h ] -> pin := Some h
        | "pin", _ -> report acc ?span:(span_of g) "E1700" "(pin ...) takes one #hash"
        | ("as" | "path" | "bundle"), _ ->
            report acc ?span:(span_of g) "E1700" "(%s ...) takes exactly one value" g.head
        | other, _ ->
            report acc ?span:(span_of g) "E1701"
              "unknown dependency field (%s ...); v1 knows as, path, bundle, and pin" other)
      fields;
    match (!alias, !source) with
    | Some alias, Some source -> Some { alias; source; pin = !pin }
    | None, _ ->
        report acc ?span:(span_of f) "E1700" "a dependency needs (as ALIAS)";
        None
    | _, None ->
        report acc ?span:(span_of f) "E1700" "dependency needs a (path ...) or (bundle ...) source";
        None

let parse_deps acc (owner : Form.t) args =
  let deps = List.filter_map (parse_dep acc) (subforms acc ~owner "(deps ...)" args) in
  check_count acc ~owner "(deps ...)" max_deps deps;
  check_unique acc ~owner "dependency alias" (fun d -> d.alias) deps;
  deps

let parse_entry acc (f : Form.t) =
  let ekind =
    match f.head with
    | "run" -> Some Run
    | "test" -> Some Test
    | other ->
        report acc ?span:(span_of f) "E1700" "unknown entry kind %s; use run or test" other;
        None
  in
  match (ekind, f.args) with
  | None, _ -> None
  | Some _, [] ->
      report acc ?span:(span_of f) "E1700" "an entry needs a name";
      None
  | Some ekind, name :: rest -> (
      match symbol acc ~owner:f "an entry name" name with
      | None -> None
      | Some ename -> (
          let fields = subforms acc ~owner:f "an entry" rest in
          check_unique acc ~owner:f "entry field" (fun (g : Form.t) -> g.head) fields;
          let eunits = ref None and grants = ref [] and native = ref false in
          List.iter
            (fun (g : Form.t) ->
              match (g.head, g.args) with
              | "units", args -> eunits := Some (unit_list acc ~owner:g "an entry unit" args)
              | "grants", args ->
                  let names = List.filter_map (symbol acc ~owner:g "a grant") args in
                  check_unique acc ~owner:g "grant" Fun.id names;
                  grants := List.sort_uniq String.compare names
              | "native", [] when ekind = Run -> native := true
              | "native", [] ->
                  report acc ?span:(span_of g) "E1701" "(native) applies only to run entries"
              | "native", _ -> report acc ?span:(span_of g) "E1700" "(native) takes no arguments"
              | other, _ ->
                  report acc ?span:(span_of g) "E1701"
                    "unknown entry field (%s ...); v1 knows units, grants, and native" other)
            fields;
          match !eunits with
          | Some eunits -> Some { ekind; ename; eunits; grants = !grants; native = !native }
          | None ->
              report acc ?span:(span_of f) "E1700" "entry %s needs (units ...)" ename;
              None))

let parse_entries acc (owner : Form.t) args =
  let entries = List.filter_map (parse_entry acc) (subforms acc ~owner "(entries ...)" args) in
  check_count acc ~owner "(entries ...)" max_entries entries;
  check_unique acc ~owner "entry" (fun e -> entry_kind_name e.ekind ^ " " ^ e.ename) entries;
  entries

let parse_metadata acc (owner : Form.t) args =
  let pairs =
    List.filter_map
      (fun (f : Form.t) ->
        match f.args with
        | [ v ] -> Option.map (fun v -> (f.head, v)) (text acc ~owner:f "a metadata value" v)
        | _ ->
            report acc ?span:(span_of f) "E1700" "metadata (%s ...) takes one text value" f.head;
            None)
      (subforms acc ~owner "(metadata ...)" args)
  in
  check_unique acc ~owner "metadata key" fst pairs;
  List.sort (fun (a, _) (b, _) -> String.compare a b) pairs

let known_fields =
  [ "name"; "requires"; "namespace"; "units"; "exports"; "deps"; "entries"; "metadata" ]

let validate acc (root : Form.t) =
  if root.head <> version then begin
    report acc ?span:(span_of root) "E1700" "unsupported manifest format %s; this tool reads %s"
      root.head version;
    None
  end
  else
    let fields = subforms acc ~owner:root "a manifest" root.args in
    check_unique acc ~owner:root "field" (fun (f : Form.t) -> f.head) fields;
    List.iter
      (fun (f : Form.t) ->
        if not (List.mem f.head known_fields) then
          report acc ?span:(span_of f) "E1701"
            "unknown field (%s ...); free-form data belongs in (metadata ...)" f.head)
      fields;
    let field name = List.find_opt (fun (f : Form.t) -> f.head = name) fields in
    let name =
      match field "name" with
      | Some ({ args = [ v ]; _ } as f) -> text acc ~owner:f "the project name" v
      | Some f ->
          report acc ?span:(span_of f) "E1700" "(name ...) takes one text value";
          None
      | None ->
          report acc ?span:(span_of root) "E1700" "a manifest needs (name \"...\")";
          None
    in
    let core =
      match field "requires" with
      | Some f -> parse_core acc f f.args
      | None ->
          report acc ?span:(span_of root) "E1700"
            "a manifest needs (requires (core \"MAJOR.MINOR\"))";
          None
    in
    let namespace =
      match field "namespace" with
      | None -> None
      | Some ({ args = [ v ]; _ } as f) -> (
          match symbol acc ~owner:f "the namespace" v with
          | Some ns when is_kebab ns -> Some ns
          | Some ns ->
              report acc ?span:(span_of f) "E1700"
                "namespace %s must be lowercase letters, digits, and inner hyphens" ns;
              None
          | None -> None)
      | Some f ->
          report acc ?span:(span_of f) "E1700" "(namespace ...) takes one symbol";
          None
    in
    let args_of name = match field name with Some f -> Some (f, f.args) | None -> None in
    let units =
      match args_of "units" with Some (f, a) -> unit_list acc ~owner:f "a unit" a | None -> []
    in
    let exports =
      match args_of "exports" with Some (f, a) -> parse_exports acc f a | None -> []
    in
    let deps = match args_of "deps" with Some (f, a) -> parse_deps acc f a | None -> [] in
    let entries =
      match args_of "entries" with Some (f, a) -> parse_entries acc f a | None -> []
    in
    let metadata =
      match args_of "metadata" with Some (f, a) -> parse_metadata acc f a | None -> []
    in
    match (name, core) with
    | Some name, Some core ->
        Some { name; core; namespace; units; exports; deps; entries; metadata }
    | _ -> None

let parse ~file src =
  if String.length src > max_bytes then
    Error
      [
        diag "E1703"
          (Printf.sprintf "%s is %d bytes; the manifest limit is %d" file (String.length src)
             max_bytes);
      ]
  else
    match Reader.parse_one ~file src with
    | Error ds ->
        Error (diag "E1700" (Printf.sprintf "%s is not a single well-formed form" file) :: ds)
    | Ok root -> (
        let acc = { errors = [] } in
        let result = validate acc root in
        match (acc.errors, result) with
        | [], Some t -> Ok t
        | [], None -> Error [ diag "E1700" "the manifest could not be validated" ]
        | errors, _ -> Error (List.rev errors))

let check_requires t ~core =
  let major, minor = t.core in
  let running =
    match String.split_on_char '.' core with
    | a :: b :: _ -> (
        match (int_of_string_opt a, int_of_string_opt b) with
        | Some a, Some b -> Some (a, b)
        | _ -> None)
    | _ -> None
  in
  match running with
  | Some (a, b) when a = major && b >= minor -> Ok ()
  | _ ->
      Error
        [
          diag "E1704"
            (Printf.sprintf
               "the project requires Core %d.%d (same major, at least that minor); running %s" major
               minor core);
        ]

(* --- canonical form --- *)

let f head args = Form.form head args
let sym s = Form.Sym s
let txt s = Form.Text s
let selector_form s = Form.F (f (kind_name s.kind) [ sym s.name ])

let dep_form d =
  let source =
    match d.source with Path p -> f "path" [ txt p ] | Bundle p -> f "bundle" [ txt p ]
  in
  Form.F
    (f "dep"
       ([ Form.F (f "as" [ sym d.alias ]); Form.F source ]
       @ match d.pin with Some h -> [ Form.F (f "pin" [ Form.Hash h ]) ] | None -> []))

let entry_form e =
  Form.F
    (f (entry_kind_name e.ekind)
       ([ sym e.ename; Form.F (f "units" (List.map txt e.eunits)) ]
       @ (if e.grants = [] then [] else [ Form.F (f "grants" (List.map sym e.grants)) ])
       @ if e.native then [ Form.F (f "native" []) ] else []))

let sorted_exports t =
  List.sort (fun a b -> compare (kind_name a.kind, a.name) (kind_name b.kind, b.name)) t.exports

let sorted_deps t = List.sort (fun a b -> String.compare a.alias b.alias) t.deps

let sorted_entries t =
  List.sort
    (fun a b -> compare (entry_kind_name a.ekind, a.ename) (entry_kind_name b.ekind, b.ename))
    t.entries

let body ~semantic t =
  let major, minor = t.core in
  List.concat
    [
      (if semantic then [] else [ Form.F (f "name" [ txt t.name ]) ]);
      [ Form.F (f "requires" [ Form.F (f "core" [ txt (Printf.sprintf "%d.%d" major minor) ]) ]) ];
      (match t.namespace with Some ns -> [ Form.F (f "namespace" [ sym ns ]) ] | None -> []);
      (if t.units = [] then [] else [ Form.F (f "units" (List.map txt t.units)) ]);
      (if t.exports = [] then []
       else [ Form.F (f "exports" (List.map selector_form (sorted_exports t))) ]);
      (if t.deps = [] then [] else [ Form.F (f "deps" (List.map dep_form (sorted_deps t))) ]);
      (if t.entries = [] then []
       else [ Form.F (f "entries" (List.map entry_form (sorted_entries t))) ]);
      (if semantic || t.metadata = [] then []
       else [ Form.F (f "metadata" (List.map (fun (k, v) -> Form.F (f k [ txt v ])) t.metadata)) ]);
    ]

let to_form t = f version (body ~semantic:false t)
let print t = Printer.print (to_form t) ^ "\n"
let semantic_projection t = f version (body ~semantic:true t)
let semantic_digest t = Hash.of_string (Printer.print (semantic_projection t))
let document_digest t = Hash.of_string (print t)

(* --- locating, reading, and writing --- *)

let file_name = "project.jqd"

let locate ?project ~cwd ?home () =
  let not_found cause = Error [ diag "E1735" cause ] in
  match project with
  | Some dir ->
      let path = Filename.concat dir file_name in
      if Sys.file_exists path then Ok path
      else not_found (Printf.sprintf "%s has no %s" dir file_name)
  | None ->
      let rec up dir =
        let path = Filename.concat dir file_name in
        if Sys.file_exists path then Ok path
        else
          let parent = Filename.dirname dir in
          let at_vcs_root = Sys.file_exists (Filename.concat dir ".git") in
          let at_home = match home with Some h -> String.equal h dir | None -> false in
          if at_vcs_root || at_home || String.equal parent dir then
            not_found
              (Printf.sprintf "no %s in %s or its parents (search stopped at %s)" file_name cwd dir)
          else up parent
      in
      up cwd

let read path =
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (e, _, _) ->
      Error [ diag "E1735" (Printf.sprintf "cannot open %s: %s" path (Unix.error_message e)) ]
  | fd ->
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () ->
          match (Unix.fstat fd).Unix.st_kind with
          | Unix.S_REG ->
              let buffer = Bytes.create (max_bytes + 1) in
              let rec fill off =
                if off > max_bytes then off
                else
                  match Unix.read fd buffer off (max_bytes + 1 - off) with
                  | 0 -> off
                  | n -> fill (off + n)
              in
              let length = fill 0 in
              if length > max_bytes then
                Error
                  [
                    diag "E1703"
                      (Printf.sprintf "%s exceeds the manifest limit of %d bytes" path max_bytes);
                  ]
              else parse ~file:path (Bytes.sub_string buffer 0 length)
          | _ -> Error [ diag "E1735" (Printf.sprintf "%s is not a regular file" path) ])

let write_canonical path t =
  let dir = Filename.dirname path in
  let temp = Filename.concat dir (Printf.sprintf ".%s.%d.tmp" file_name (Unix.getpid ())) in
  let contents = print t in
  match
    let fd =
      Unix.openfile temp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o644
    in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        let bytes = Bytes.of_string contents in
        let rec out off =
          if off < Bytes.length bytes then
            out (off + Unix.write fd bytes off (Bytes.length bytes - off))
        in
        out 0;
        Unix.fsync fd);
    Unix.rename temp path
  with
  | () -> Ok ()
  | exception Unix.Unix_error (e, _, _) ->
      (try Unix.unlink temp with Unix.Unix_error _ -> ());
      Error [ diag "E1735" (Printf.sprintf "cannot write %s: %s" path (Unix.error_message e)) ]
