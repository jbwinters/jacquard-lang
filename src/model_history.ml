(* MODEL.1 history, snapshots and explanations (docs/designs/model-dependencies.md §3.5). *)

let ( let* ) = Result.bind
let hex = Hash.to_hex

let document_identity file =
  let path =
    try Unix.realpath file
    with Unix.Unix_error _ ->
      if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file else file
  in
  Hash.of_string ("jacquard-model-document-v1\000" ^ path)

type binding = { kind : string; name : string; snapshot : Hash.t option }

type record = {
  time : string;
  entry_name : string;
  entry_closure : Hash.t option;
  key : Hash.t;
  previous : Hash.t option;
  outcome : string;
  source : Hash.t;
  interface : Hash.t;
  policy_snapshot : Hash.t;
  bindings : binding list;
  dependency : Model_doc.dependency;
}

let header = "jacquard-model-history format=1"
let opt_hex = function Some h -> hex h | None -> "none"

let serialize_record r =
  let buf = Buffer.create 512 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string buf (s ^ "\n")) fmt in
  line "%s" header;
  line "time %s" r.time;
  line "entry-name %s" r.entry_name;
  (* records written before closures existed have no entry-closure line, and still parse *)
  Option.iter (fun h -> line "entry-closure %s" (hex h)) r.entry_closure;
  line "key %s" (hex r.key);
  line "previous %s" (opt_hex r.previous);
  line "outcome %s" r.outcome;
  line "source %s interface %s" (hex r.source) (hex r.interface);
  line "policy-snapshot %s" (hex r.policy_snapshot);
  line "bindings %d" (List.length r.bindings);
  List.iteri
    (fun i b -> line "binding %d %s %s snapshot %s" i b.kind b.name (opt_hex b.snapshot))
    r.bindings;
  Buffer.add_string buf (Model_doc.serialize_dependency r.dependency);
  Buffer.contents buf

let natural s =
  if s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s && (s = "0" || s.[0] <> '0') then
    int_of_string_opt s
  else None

let parse_record bytes =
  let fail fmt = Printf.ksprintf (fun m -> Error m) fmt in
  let hash s = match Hash.of_canonical_hex s with Some h -> Ok h | None -> fail "bad hash" in
  let opt s = if s = "none" then Ok None else Result.map Option.some (hash s) in
  let lines = String.split_on_char '\n' bytes in
  let after prefix l =
    if String.starts_with ~prefix l then
      Ok (String.sub l (String.length prefix) (String.length l - String.length prefix))
    else fail "expected %S" prefix
  in
  let closure, lines =
    match lines with
    | h :: t :: e :: c :: rest when String.starts_with ~prefix:"entry-closure " c ->
        (Some c, h :: t :: e :: rest)
    | _ -> (None, lines)
  in
  match lines with
  | h :: time :: entry :: key :: previous :: outcome :: provenance :: policy :: count :: rest
    when h = header ->
      let* time = after "time " time in
      let* entry_name = after "entry-name " entry in
      let* entry_closure =
        match closure with
        | None -> Ok None
        | Some c ->
            Result.bind (after "entry-closure " c) (fun s -> Result.map Option.some (hash s))
      in
      let* key = Result.bind (after "key " key) hash in
      let* previous = Result.bind (after "previous " previous) opt in
      let* outcome = after "outcome " outcome in
      let* source, interface =
        match String.split_on_char ' ' provenance with
        | [ "source"; s; "interface"; i ] ->
            let* s = hash s in
            let* i = hash i in
            Ok (s, i)
        | _ -> fail "bad provenance line"
      in
      let* policy_snapshot = Result.bind (after "policy-snapshot " policy) hash in
      let* n =
        Result.bind (after "bindings " count) (fun s ->
            Option.to_result ~none:"bad count" (natural s))
      in
      if List.length rest < n then fail "missing bindings"
      else
        let binding_lines = List.filteri (fun i _ -> i < n) rest in
        let* bindings =
          List.fold_right
            (fun (i, l) acc ->
              let* acc = acc in
              match String.split_on_char ' ' l with
              | [ "binding"; j; kind; name; "snapshot"; s ] when j = string_of_int i ->
                  let* snapshot = opt s in
                  Ok ({ kind; name; snapshot } :: acc)
              | _ -> fail "bad binding line")
            (List.mapi (fun i l -> (i, l)) binding_lines)
            (Ok [])
        in
        let dependency_text = String.concat "\n" (List.filteri (fun i _ -> i >= n) rest) in
        let* dependency = Model_doc.parse_dependency dependency_text in
        let r =
          {
            time;
            entry_name;
            entry_closure;
            key;
            previous;
            outcome;
            source;
            interface;
            policy_snapshot;
            bindings;
            dependency;
          }
        in
        let consistent (b : binding) (a : Model_doc.argument_identity) =
          match (b.kind, a) with
          | ("assumption" | "inline"), Model_doc.Assumption _ -> b.snapshot <> None
          | "input", Model_doc.Input h -> (
              match b.snapshot with Some s -> Hash.equal s h | None -> false)
          | "term", Model_doc.Term _ -> true
          | _ -> false
        in
        if serialize_record r <> bytes then fail "noncanonical record"
        else if not (Hash.equal key (Model_doc.key dependency)) then
          fail "the record's key does not match its dependency record"
        else if
          List.length bindings <> List.length dependency.Model_doc.arguments
          || not (List.for_all2 consistent bindings dependency.Model_doc.arguments)
        then fail "the record's bindings do not match its arguments"
        else Ok r
  | _ -> fail "not a history record"

(* the records before the first bad frame, and that frame's offset and the reason *)
let parse_prefix bytes =
  let n = String.length bytes in
  let rec go pos acc =
    let stop reason = (List.rev acc, Some (pos, reason)) in
    if pos = n then (List.rev acc, None)
    else
      match String.index_from_opt bytes pos '\n' with
      | None -> stop "truncated frame"
      | Some j -> (
          let l = String.sub bytes pos (j - pos) in
          match String.split_on_char '=' l with
          | [ "entry bytes"; k ] -> (
              match natural k with
              | Some k when k < n - j - 1 && bytes.[j + 1 + k] = '\n' -> (
                  match parse_record (String.sub bytes (j + 1) k) with
                  | Ok r -> go (j + 2 + k) (r :: acc)
                  | Error reason -> stop reason)
              | _ -> stop "bad frame length")
          | _ -> stop "bad frame")
  in
  go 0 []

let parse_history bytes =
  match parse_prefix bytes with records, None -> Ok records | _, Some (_, reason) -> Error reason

let history_path ~cache ~document name =
  Filename.concat (Filename.concat (Filename.concat cache "history") (hex document)) name

let snapshot_path ~cache h = Filename.concat (Filename.concat cache "snapshots") (hex h)

let read_history ~cache ~document name =
  match Model_doc.read_bounded ~limit:(64 * 1024 * 1024) (history_path ~cache ~document name) with
  | Error `Absent -> Ok []
  | Error (`Unreadable reason) -> Error reason
  | Ok bytes -> parse_history bytes

let read_snapshot ~cache h =
  match Model_doc.read_bounded ~limit:(16 * 1024 * 1024) (snapshot_path ~cache h) with
  | Ok bytes when Hash.equal (Hash.of_string bytes) h -> Some bytes
  | _ -> None

let now () =
  let t = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1)
    t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let write_snapshot ~cache content =
  let h = Hash.of_string content in
  let path = snapshot_path ~cache h in
  (* an existing snapshot is kept only when it still holds its content *)
  if read_snapshot ~cache h <> None then Ok h
  else Result.map (fun () -> h) (Model_eval.write_atomic path content)

let append_frame path bytes =
  try
    Model_eval.make_dirs (Filename.dirname path);
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600
    in
    Fun.protect
      ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
      (fun () ->
        let frame = Printf.sprintf "entry bytes=%d\n%s\n" (String.length bytes) bytes in
        let b = Bytes.unsafe_of_string frame in
        let rec go off =
          if off < Bytes.length b then go (off + Unix.write fd b off (Bytes.length b - off))
        in
        go 0;
        Unix.fsync fd);
    Ok ()
  with (Unix.Unix_error _ | Sys_error _) as e -> Error (Printexc.to_string e)

(* one writer at a time per history: the read, the decision and the write happen under an
   exclusive lock on a sibling lock file *)
let with_lock path f =
  match
    Model_eval.make_dirs (Filename.dirname path);
    Unix.openfile (path ^ ".lock") [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600
  with
  | exception ((Unix.Unix_error _ | Sys_error _) as e) -> Error (Printexc.to_string e)
  | fd ->
      Fun.protect
        ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
        (fun () ->
          match Unix.lockf fd Unix.F_LOCK 0 with
          | exception Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)
          | () -> f ())

let kind_text = function
  | Resolve.KTerm -> "term"
  | Resolve.KCon -> "con"
  | Resolve.KOp -> "op"
  | Resolve.KType -> "type"
  | Resolve.KEffect -> "effect"

(* the closure manifest of a term: every declaration it reaches, one line per (name, kind) bound
   to a member of it, or one unnamed line, each with a snapshot of its stored bytes ("none" when
   they cannot be read), sorted; and the bodies to retain *)
let closure ~(store : Store.t) root =
  let owner = Hashtbl.create 256 in
  List.iter (fun (h, (d, _)) -> Hashtbl.replace owner (hex h) d) store.Store.index;
  let names = Hashtbl.create 256 in
  List.iter
    (fun (name, (e : Resolve.entry)) ->
      match Hashtbl.find_opt owner (hex e.Resolve.hash) with
      | Some d -> Hashtbl.add names (hex d) (name, kind_text e.Resolve.kind)
      | None -> ())
    (Store.names store);
  let seen = Hashtbl.create 64 in
  let rec visit acc h =
    let d = match Hashtbl.find_opt owner (hex h) with Some d -> hex d | None -> hex h in
    if Hashtbl.mem seen d then acc
    else (
      Hashtbl.add seen d ();
      match Store.locate_internal store h with
      | Error _ -> acc
      | Ok l -> List.fold_left visit (l.Store.decl_hash :: acc) (Store.decl_refs l.Store.decl))
  in
  let decls = visit [] root in
  let bodies =
    List.map
      (fun d ->
        match Model_doc.read_bounded ~limit:(16 * 1024 * 1024) (Store.object_path store d) with
        | Ok body -> (d, Some body)
        | Error _ -> (d, None))
      decls
  in
  let lines =
    List.concat_map
      (fun (d, body) ->
        let b = match body with Some b -> hex (Hash.of_string b) | None -> "none" in
        match Hashtbl.find_all names (hex d) with
        | [] -> [ Printf.sprintf "- - %s %s" (hex d) b ]
        | ns -> List.map (fun (n, k) -> Printf.sprintf "%s %s %s %s" n k (hex d) b) ns)
      bodies
    |> List.sort_uniq compare
  in
  ( "jacquard-model-closure format=1\n" ^ String.concat "" (List.map (fun l -> l ^ "\n") lines),
    List.filter_map snd bodies )

(* ((name, kind), decl, body) per line; unnamed lines have name "-" *)
let parse_closure text =
  match String.split_on_char '\n' text with
  | "jacquard-model-closure format=1" :: rest ->
      Some
        (List.filter_map
           (fun l ->
             match String.split_on_char ' ' l with
             | [ n; k; d; b ] -> Some ((n, k), d, b)
             | _ -> None)
           rest)
  | _ -> None

let append ~cache ~document (prepared : Model_doc.prepared) (r : Model_doc.resolved) ~outcome =
  let name = r.Model_doc.decl.Model_doc.r_name in
  let path = history_path ~cache ~document name in
  with_lock path @@ fun () ->
  let key = Model_doc.key r.Model_doc.dependency in
  (* a damaged history keeps every record before the damage; an unreadable one is left alone *)
  let* history, damage =
    match Model_doc.read_bounded ~limit:(64 * 1024 * 1024) path with
    | Error `Absent -> Ok ([], None)
    | Error (`Unreadable reason) -> Error reason
    | Ok bytes -> (
        match parse_prefix bytes with
        | records, None -> Ok (records, None)
        | records, Some (offset, reason) -> Ok (records, Some (String.sub bytes 0 offset, reason)))
  in
  (* another format version: the marker followed by a complete version line other than 1 *)
  let other_format bytes =
    let marker = "\njacquard-model-history format=" in
    let m = String.length marker and n = String.length bytes in
    let rec scan i =
      if i + m > n then false
      else if String.sub bytes i m = marker then
        match String.index_from_opt bytes (i + m) '\n' with
        | Some e ->
            let v = String.sub bytes (i + m) (e - i - m) in
            (v <> "1" && v <> "" && String.for_all (fun c -> c >= '0' && c <= '9') v) || scan (i + 1)
        | None -> false
      else scan (i + 1)
    in
    scan 0
  in
  let* () =
    match damage with
    | Some _
      when match Model_doc.read_bounded ~limit:(64 * 1024 * 1024) path with
           | Ok bytes -> other_format bytes
           | Error _ -> false ->
        Error "the history holds a record of another format; it was left untouched"
    | _ -> Ok ()
  in
  (* snapshots are written, or repaired, on every evaluation, so pruning them never sticks *)
  let* bindings =
    List.fold_right
      (fun (b : Model_doc.binding) acc ->
        let* acc = acc in
        let* snapshot =
          match b.Model_doc.b_content with
          | None -> Ok None
          | Some c -> Result.map Option.some (write_snapshot ~cache c)
        in
        Ok ({ kind = b.Model_doc.b_kind; name = b.Model_doc.b_name; snapshot } :: acc))
      r.Model_doc.bindings (Ok [])
  in
  let* policy_snapshot =
    write_snapshot ~cache (Observation_policy.serialize prepared.Model_doc.policy)
  in
  (* the entry's and each term argument's closure: bodies and manifest, retained *)
  let write_closure h =
    let text, bodies = closure ~store:prepared.Model_doc.store h in
    let* () =
      List.fold_left
        (fun acc body ->
          let* () = acc in
          Result.map ignore (write_snapshot ~cache body))
        (Ok ()) bodies
    in
    write_snapshot ~cache text
  in
  let* entry_closure = write_closure r.Model_doc.dependency.Model_doc.entry in
  let* bindings =
    List.fold_right2
      (fun b a acc ->
        let* acc = acc in
        match a with
        | Model_doc.Term { term; _ } ->
            let* m = write_closure term in
            Ok ({ b with snapshot = Some m } :: acc)
        | _ -> Ok (b :: acc))
      bindings r.Model_doc.dependency.Model_doc.arguments (Ok [])
  in
  let note =
    Option.map
      (fun (_, reason) ->
        Printf.sprintf "the history was damaged (%s); its %d earlier record(s) were kept" reason
          (List.length history))
      damage
  in
  let latest = match List.rev history with r :: _ -> Some r | [] -> None in
  let frame bytes = Printf.sprintf "entry bytes=%d\n%s\n" (String.length bytes) bytes in
  (* the latest record still names a snapshot that is gone (an equal respelling of an
     assumption keeps the key but changes its text): refresh it with a record naming the
     current snapshots *)
  let stale_refs (l : record) =
    List.exists
      (fun b -> match b.snapshot with Some h -> read_snapshot ~cache h = None | None -> false)
      l.bindings
    || read_snapshot ~cache l.policy_snapshot = None
    || match l.entry_closure with Some h -> read_snapshot ~cache h = None | None -> true
  in
  match latest with
  | Some l when Hash.equal l.key key && not (stale_refs l) -> (
      match damage with
      | None -> Ok None
      | Some (kept, _) -> Result.map (fun () -> note) (Model_eval.write_atomic path kept))
  | _ -> (
      let record =
        {
          time = now ();
          entry_name = r.Model_doc.decl.Model_doc.r_entry;
          entry_closure = Some entry_closure;
          key;
          previous = Option.map (fun l -> l.key) latest;
          outcome;
          source = Frontend.Checked.source_digest prepared.Model_doc.artifact;
          interface = Interface.identity (Frontend.Checked.interface prepared.Model_doc.artifact);
          policy_snapshot;
          bindings;
          dependency = r.Model_doc.dependency;
        }
      in
      let bytes = serialize_record record in
      match damage with
      | Some (kept, _) ->
          Result.map (fun () -> note) (Model_eval.write_atomic path (kept ^ frame bytes))
      | None -> Result.map (fun () -> None) (append_frame path bytes))

(* --- explanations --- *)

type change = {
  component : string;
  subject : string option;
  before : string option;
  after : string option;
}

type freshness =
  | Current
  | Unknown of string list
  | Stale of change list
  | Never_evaluated
  | Unavailable of string

type explanation = {
  result : string;
  evaluated_at : string option;
  outcome : string option;
  previous : Hash.t option;
  missing : string list;
  freshness : freshness;
  transition : (string * change list) option;
  transition_missing : string list;
}

(* one side of a comparison: a record, or the document as it is now *)
type side = {
  entry : string;
  entry_closure : Hash.t option;
  dep : Model_doc.dependency;
  binds : binding list;
  content : Hash.t -> string option;
}

let driver_text (d : Model_doc.dependency) =
  match d.Model_doc.driver with
  | Model_doc.Run -> "run"
  | Model_doc.Enumerate { max_branches } -> Printf.sprintf "enumerate max-branches=%d" max_branches
  | Model_doc.Lw { seed; samples } -> Printf.sprintf "lw seed=%d samples=%d" seed samples

let shown content = function
  | None -> "(unavailable)"
  | Some h -> ( match content h with Some text -> text | None -> "(unavailable)")

let byte_count content = function
  | None -> "(unavailable)"
  | Some h -> (
      match content h with
      | Some bytes -> Printf.sprintf "%d bytes" (String.length bytes)
      | None -> "(unavailable)")

let differences old_ now_ =
  let change ?subject ?before ?after component = { component; subject; before; after } in
  (* the named declarations that differ between two closure manifests, the root's own name aside *)
  let callees ~root old_c new_c =
    let manifest side = function
      | None -> None
      | Some h -> Option.bind (side.content h) parse_closure
    in
    match (manifest old_ old_c, manifest now_ new_c) with
    | Some o, Some n ->
        let named m = List.filter (fun ((name, _), _, _) -> name <> "-") m in
        let o = named o and n = named n in
        (* the root's own declaration, with its group siblings, is the change itself *)
        let root_decls =
          List.filter_map (fun ((name, _), d, _) -> if name = root then Some d else None) (o @ n)
        in
        let decls m key =
          List.sort_uniq compare
            (List.filter_map (fun (k, d, _) -> if k = key then Some d else None) m)
        in
        let keys = List.sort_uniq compare (List.map (fun (k, _, _) -> k) (o @ n)) in
        List.filter_map
          (fun ((name, _) as key) ->
            let a = decls o key and b = decls n key in
            if List.exists (fun d -> List.mem d root_decls) (a @ b) then None
            else
              match (a, b) with
              | [], _ :: _ -> Some (change ~subject:name ~after:"added" "callee")
              | _ :: _, [] -> Some (change ~subject:name ~after:"removed" "callee")
              | a, b when a <> b -> Some (change ~subject:name "callee")
              | _ -> None)
          keys
    | _ -> []
  in
  let o = old_.dep and n = now_.dep in
  let some c b = if c then [ b ] else [] in
  let entry =
    some
      ((not (Hash.equal o.Model_doc.entry n.Model_doc.entry)) || old_.entry <> now_.entry)
      (if old_.entry <> now_.entry then change ~before:old_.entry ~after:now_.entry "entry"
       else change ~subject:now_.entry "entry")
    @
    if Hash.equal o.Model_doc.entry n.Model_doc.entry then []
    else callees ~root:now_.entry old_.entry_closure now_.entry_closure
  in
  let fixed =
    some
      (not (Hash.equal o.Model_doc.signature n.Model_doc.signature))
      (change ~subject:now_.entry "signature")
    @ some (o.Model_doc.labels <> n.Model_doc.labels) (change ~subject:now_.entry "labels")
    @ some (o.Model_doc.prelude <> n.Model_doc.prelude) (change "prelude")
    @ some
        (o.Model_doc.core <> n.Model_doc.core)
        (change ~before:o.Model_doc.core ~after:n.Model_doc.core "core")
    @ some
        (driver_text o <> driver_text n)
        (change ~before:(driver_text o) ~after:(driver_text n) "driver")
    @ some
        (o.Model_doc.fuel <> n.Model_doc.fuel)
        (change ~before:(string_of_int o.Model_doc.fuel) ~after:(string_of_int n.Model_doc.fuel)
           "fuel")
    @ some (not (Hash.equal o.Model_doc.policy n.Model_doc.policy)) (change "policy")
  in
  let oa = o.Model_doc.arguments and na = n.Model_doc.arguments in
  let count =
    some
      (List.length oa <> List.length na)
      (change
         ~before:(string_of_int (List.length oa))
         ~after:(string_of_int (List.length na))
         "arguments")
  in
  let rec pairs i ob nb oi ni =
    match (ob, nb, oi, ni) with
    | b0 :: ob, b1 :: nb, i0 :: oi, i1 :: ni ->
        let here =
          if b0.kind <> b1.kind || b0.name <> b1.name then
            [
              change ~subject:(Printf.sprintf "argument %d" i)
                ~before:(b0.kind ^ " " ^ b0.name)
                ~after:(b1.kind ^ " " ^ b1.name)
                "argument";
            ]
          else if i0 = i1 then []
          else
            match b1.kind with
            | "assumption" | "inline" ->
                [
                  change ~subject:b1.name ~before:(shown old_.content b0.snapshot)
                    ~after:(shown now_.content b1.snapshot) b1.kind;
                ]
            | "input" ->
                [
                  change ~subject:b1.name
                    ~before:(byte_count old_.content b0.snapshot)
                    ~after:(byte_count now_.content b1.snapshot)
                    "input";
                ]
            | kind -> change ~subject:b1.name kind :: callees ~root:b1.name b0.snapshot b1.snapshot
        in
        here @ pairs (i + 1) ob nb oi ni
    | _ -> []
  in
  entry @ fixed @ count @ pairs 0 old_.binds now_.binds oa na

let explain ~cache ~document (prepared : Model_doc.prepared) =
  let policy_bytes = Observation_policy.serialize prepared.Model_doc.policy in
  let one (r : Model_doc.resolved) =
    let name = r.Model_doc.decl.Model_doc.r_name in
    let manifest h = fst (closure ~store:prepared.Model_doc.store h) in
    let entry_manifest = manifest r.Model_doc.dependency.Model_doc.entry in
    let term_manifests =
      List.map
        (function Model_doc.Term { term; _ } -> Some (manifest term) | _ -> None)
        r.Model_doc.dependency.Model_doc.arguments
    in
    let current_contents =
      (policy_bytes :: entry_manifest :: List.filter_map Fun.id term_manifests)
      @ List.filter_map (fun (b : Model_doc.binding) -> b.Model_doc.b_content) r.Model_doc.bindings
    in
    let now_ =
      {
        entry = r.Model_doc.decl.Model_doc.r_entry;
        entry_closure = Some (Hash.of_string entry_manifest);
        dep = r.Model_doc.dependency;
        binds =
          List.map2
            (fun (b : Model_doc.binding) m ->
              {
                kind = b.Model_doc.b_kind;
                name = b.Model_doc.b_name;
                snapshot =
                  (match m with
                  | Some text -> Some (Hash.of_string text)
                  | None -> Option.map Hash.of_string b.Model_doc.b_content);
              })
            r.Model_doc.bindings term_manifests;
        content =
          (fun h ->
            match List.find_opt (fun c -> Hash.equal (Hash.of_string c) h) current_contents with
            | Some c -> Some c
            | None -> read_snapshot ~cache h);
      }
    in
    let of_record (rc : record) =
      {
        entry = rc.entry_name;
        entry_closure = rc.entry_closure;
        dep = rc.dependency;
        binds = rc.bindings;
        content = read_snapshot ~cache;
      }
    in
    match read_history ~cache ~document name with
    | Error reason ->
        {
          result = name;
          evaluated_at = None;
          outcome = None;
          previous = None;
          missing = [];
          freshness = Unavailable reason;
          transition = None;
          transition_missing = [];
        }
    | Ok history -> (
        match List.rev history with
        | [] ->
            {
              result = name;
              evaluated_at = None;
              outcome = None;
              previous = None;
              missing = [];
              freshness = Never_evaluated;
              transition = None;
              transition_missing = [];
            }
        | latest :: earlier -> (
            (* a policy snapshot that is present must be the policy its record names *)
            let policy_mismatch (rc : record) =
              match read_snapshot ~cache rc.policy_snapshot with
              | None -> false
              | Some bytes -> (
                  match Observation_policy.parse bytes with
                  | Ok p ->
                      not
                        (Hash.equal (Observation_policy.identity p) rc.dependency.Model_doc.policy)
                  | Error _ -> true)
            in
            match List.find_opt policy_mismatch history with
            | Some _ ->
                {
                  result = name;
                  evaluated_at = Some latest.time;
                  outcome = Some latest.outcome;
                  previous = latest.previous;
                  missing = [];
                  freshness = Unavailable "a record's policy snapshot is not its policy";
                  transition = None;
                  transition_missing = [];
                }
            | None ->
                (* a dependency whose snapshot is gone is never assumed current, and is always named *)
                (* a manifest's retained bodies count as its snapshots *)
                let bodies_gone what manifest =
                  match Option.bind manifest parse_closure with
                  | None -> []
                  | Some lines ->
                      if
                        List.exists
                          (fun (_, _, b) ->
                            b = "none"
                            ||
                            match Hash.of_canonical_hex b with
                            | Some h -> read_snapshot ~cache h = None
                            | None -> true)
                          lines
                      then [ what ^ " declarations" ]
                      else []
                in
                let gone_of (rc : record) =
                  List.concat_map
                    (fun b ->
                      match b.snapshot with
                      | Some h -> (
                          match read_snapshot ~cache h with
                          | None -> [ b.kind ^ " " ^ b.name ]
                          | Some text when b.kind = "term" ->
                              bodies_gone ("term " ^ b.name) (Some text)
                          | Some _ -> [])
                      | None -> [])
                    rc.bindings
                  @ (if read_snapshot ~cache rc.policy_snapshot = None then [ "policy" ] else [])
                  @
                  match rc.entry_closure with
                  | None -> []
                  | Some h -> (
                      match read_snapshot ~cache h with
                      | None -> [ "entry " ^ rc.entry_name ]
                      | Some text -> bodies_gone ("entry " ^ rc.entry_name) (Some text))
                in
                let gone = gone_of latest in
                let freshness =
                  if Hash.equal latest.key (Model_doc.key r.Model_doc.dependency) then
                    if gone = [] then Current else Unknown gone
                  else Stale (differences (of_record latest) now_)
                in
                (* records refreshing the latest key are one recomputation: the transition is
                   from the last record with another key, at the run's first record *)
                let rec split run = function
                  | rc :: rest when Hash.equal rc.key latest.key -> split (rc :: run) rest
                  | rest -> (run, rest)
                in
                let run, before = split [ latest ] earlier in
                let first = List.hd run in
                let transition, transition_missing =
                  match before with
                  | prev :: _ ->
                      ( Some (first.time, differences (of_record prev) (of_record latest)),
                        gone_of prev )
                  | [] -> (None, [])
                in
                (* a refresh is not a recomputation: report the run's first record *)
                {
                  result = name;
                  evaluated_at = Some first.time;
                  outcome = Some first.outcome;
                  previous = first.previous;
                  missing = gone;
                  freshness;
                  transition;
                  transition_missing;
                }))
  in
  List.map one prepared.Model_doc.resolved

let change_text c =
  let subject = match c.subject with Some s -> " " ^ s | None -> "" in
  match (c.before, c.after) with
  | Some b, Some a -> Printf.sprintf "%s%s: %s -> %s" c.component subject b a
  | None, Some status -> Printf.sprintf "%s%s %s" c.component subject status
  | _ -> Printf.sprintf "%s%s changed" c.component subject

let render_text e =
  let head =
    match e.freshness with
    | Current ->
        Printf.sprintf "%s: current (evaluated %s)" e.result
          (Option.value e.evaluated_at ~default:"?")
    | Stale _ ->
        Printf.sprintf "%s: stale (last evaluated %s)" e.result
          (Option.value e.evaluated_at ~default:"?")
    | Unknown gone ->
        Printf.sprintf "%s: unknown (snapshots gone: %s)" e.result (String.concat ", " gone)
    | Never_evaluated -> Printf.sprintf "%s: never evaluated" e.result
    | Unavailable reason -> Printf.sprintf "%s: history unavailable (%s)" e.result reason
  in
  let stale =
    match e.freshness with
    | Stale cs ->
        List.map (fun c -> "  " ^ change_text c) cs
        @ if e.missing = [] then [] else [ "  snapshots gone: " ^ String.concat ", " e.missing ]
    | _ -> []
  in
  let transition =
    match e.transition with
    | None -> []
    | Some (time, cs) ->
        (Printf.sprintf "  last change (%s):" time :: List.map (fun c -> "    " ^ change_text c) cs)
        @
        if e.transition_missing = [] then []
        else [ "    snapshots gone: " ^ String.concat ", " e.transition_missing ]
  in
  (head :: stale) @ transition

let change_json c =
  let o = function Some s -> `String s | None -> `Null in
  `Assoc
    [
      ("component", `String c.component);
      ("subject", o c.subject);
      ("before", o c.before);
      ("after", o c.after);
    ]

let to_json es =
  let one e =
    let freshness, extra =
      match e.freshness with
      | Current -> ("current", [])
      | Stale cs -> ("stale", [ ("changes", `List (List.map change_json cs)) ])
      | Unknown _ -> ("unknown", [])
      | Never_evaluated -> ("never-evaluated", [])
      | Unavailable reason -> ("history-unavailable", [ ("reason", `String reason) ])
    in
    `Assoc
      ([
         ("name", `String e.result);
         ("freshness", `String freshness);
         ("evaluated_at", match e.evaluated_at with Some t -> `String t | None -> `Null);
         ("outcome", match e.outcome with Some o -> `String o | None -> `Null);
         ("previous", match e.previous with Some h -> `String (hex h) | None -> `Null);
         ("missing", `List (List.map (fun m -> `String m) e.missing));
       ]
      @ extra
      @ [
          ( "last_transition",
            match e.transition with
            | None -> `Null
            | Some (t, cs) ->
                `Assoc
                  [
                    ("at", `String t);
                    ("changes", `List (List.map change_json cs));
                    ("missing", `List (List.map (fun m -> `String m) e.transition_missing));
                  ] );
        ])
  in
  Yojson.Safe.to_string
    (`Assoc
       [ ("format", `String "jacquard-model-explain-v1"); ("results", `List (List.map one es)) ])
