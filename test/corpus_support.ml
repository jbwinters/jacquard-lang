(** Shared plumbing for corpus-driven tests and the golden generator: the deterministic stub name
    environment (until W2.6's real prelude replaces it), file IO, and the full
    parse-validate-resolve-hash pipeline. *)

open Jacquard

(* Deterministic fake globals: hash of "stub:<name>". Regenerate the golden hashes when the
   real prelude replaces this environment. *)
let stub_hash name = Hash.of_string ("stub:" ^ name)

let stub_entries =
  List.map
    (fun (n, k) -> (n, { Resolve.hash = stub_hash n; kind = k }))
    [
      ("add", Resolve.KTerm);
      ("sub", Resolve.KTerm);
      ("mul", Resolve.KTerm);
      ("div", Resolve.KTerm);
      ("eq", Resolve.KTerm);
      ("body", Resolve.KTerm);
      ("true", Resolve.KCon);
      ("false", Resolve.KCon);
      ("some", Resolve.KCon);
      ("none", Resolve.KCon);
      ("abort", Resolve.KOp);
      ("print", Resolve.KOp);
      ("int", Resolve.KType);
      ("text", Resolve.KType);
      ("option", Resolve.KType);
      ("console", Resolve.KEffect);
      ("net", Resolve.KEffect);
      ("clock", Resolve.KEffect);
      ("fleet", Resolve.KType);
      ("map", Resolve.KTerm);
      ("list.map", Resolve.KTerm);
      ("text.join", Resolve.KTerm);
      ("int.gt?", Resolve.KTerm);
      ("int.gte?", Resolve.KTerm);
      ("int.lt?", Resolve.KTerm);
      ("int.lte?", Resolve.KTerm);
      ("real.gt?", Resolve.KTerm);
      ("real.gte?", Resolve.KTerm);
      ("real.lt?", Resolve.KTerm);
      ("real.lte?", Resolve.KTerm);
      ("cons", Resolve.KCon);
      ("nil", Resolve.KCon);
      ("eval-code", Resolve.KOp);
    ]

let stub_names = Resolve.of_alist stub_entries

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let jqd_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".jqd")
  |> List.sort String.compare

let jac_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".jac")
  |> List.sort String.compare

(** Pipeline stages, in order; invalid corpus cases name the stage they must die at. *)
type stage = Parse | Validate | Resolve | Hashing

let stage_name = function
  | Parse -> "parse"
  | Validate -> "validate"
  | Resolve -> "resolve"
  | Hashing -> "hash"

let stage_of_name = function
  | "parse" -> Some Parse
  | "validate" -> Some Validate
  | "resolve" -> Some Resolve
  | "hash" -> Some Hashing
  | _ -> None

(** Run the full pipeline on one source string, reporting which stage failed. *)
let staged_pipeline ~file src : (Canon.decl_hashes list, stage * Diag.t list) result =
  match Reader.parse_string ~file src with
  | Error ds -> Error (Parse, ds)
  | Ok forms ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | f :: rest -> (
            match Kernel.of_form f with
            | Error ds -> Error (Validate, ds)
            | Ok top -> (
                match Resolve.resolve stub_names top with
                | Error ds -> Error (Resolve, ds)
                | Ok resolved -> (
                    match Canon.hash_top resolved with
                    | Error ds -> Error (Hashing, ds)
                    | Ok hs -> go (hs :: acc) rest)))
      in
      go [] forms

(** [staged_pipeline] with the stage dropped. *)
let pipeline ~file src : (Canon.decl_hashes list, Diag.t list) result =
  Result.map_error snd (staged_pipeline ~file src)

(** Parse and validate a bootstrap file into kernel tops. *)
let bootstrap_tops ~file src : (Kernel.top list, stage * Diag.t list) result =
  match Reader.parse_string ~file src with
  | Error ds -> Error (Parse, ds)
  | Ok forms ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | form :: rest -> (
            match Kernel.of_form form with
            | Error ds -> Error (Validate, ds)
            | Ok top -> go (top :: acc) rest)
      in
      go [] forms

(** Strictly parse and lower a surface file, then pass every lowered top through the generic kernel
    validator. This keeps corpus twins on the same validation boundary as bootstrap files. *)
let surface_tops ~file src : (Kernel.top list, stage * Diag.t list) result =
  let recovered = Surface_parse.recover_string ~file src in
  match Surface_parse.strict recovered with
  | Error ds -> Error (Parse, ds)
  | Ok parsed -> (
      match Surface_lower.lower_tops parsed with
      | Error ds -> Error (Validate, ds)
      | Ok tops ->
          let rec validate acc = function
            | [] -> Ok (List.rev acc)
            | top :: rest -> (
                match Kernel.of_form (Kernel.to_form top) with
                | Error ds -> Error (Validate, ds)
                | Ok validated -> validate (validated :: acc) rest)
          in
          validate [] tops)

(** Resolve and hash kernel tops in source order. Failures retain the pipeline stage for actionable
    twin diagnostics. *)
let resolve_and_hash tops : (Canon.decl_hashes list, stage * Diag.t list) result =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | top :: rest -> (
        match Resolve.resolve stub_names top with
        | Error ds -> Error (Resolve, ds)
        | Ok resolved -> (
            match Canon.hash_top resolved with
            | Error ds -> Error (Hashing, ds)
            | Ok hashes -> go (hashes :: acc) rest))
  in
  go [] tops

(** Stable, path-independent identity lines for comparing twin pipelines. *)
let identity_lines hashes =
  List.concat
    (List.mapi
       (fun index { Canon.decl_hash; named } ->
         Printf.sprintf "%d %s" index (Hash.to_hex decl_hash)
         :: List.map
              (fun (name, hash) -> Printf.sprintf "%d:%s %s" index name (Hash.to_hex hash))
              named)
       hashes)

(** Render a deterministic mismatch report containing both source paths and both complete identity
    sets. This function does not decide whether the sets match. *)
let twin_mismatch_message ~bootstrap_path ~bootstrap_hashes ~surface_path ~surface_hashes =
  let render path hashes =
    Printf.sprintf "%s\n  %s" path (String.concat "\n  " (identity_lines hashes))
  in
  Printf.sprintf "surface twin hash mismatch:\n%s\n%s"
    (render bootstrap_path bootstrap_hashes)
    (render surface_path surface_hashes)

(** Parse a corpus [.expect] sidecar: line 1 [stage: <parse|validate|resolve|hash|check>], line 2
    [code: E0xxx]. Returns the raw stage name; runners map it. *)
let parse_expect src : (string * string) option =
  let strip s = String.trim s in
  match String.split_on_char '\n' src |> List.map strip |> List.filter (fun l -> l <> "") with
  | [ stage_line; code_line ]
    when String.length stage_line > 6
         && String.sub stage_line 0 6 = "stage:"
         && String.length code_line > 5
         && String.sub code_line 0 5 = "code:" ->
      let stage = strip (String.sub stage_line 6 (String.length stage_line - 6)) in
      let code = strip (String.sub code_line 5 (String.length code_line - 5)) in
      Some (stage, code)
  | _ -> None

(** Golden lines for one file: [file:idx <hex>] for each top form, plus [file:idx:name <hex>] for
    each named hash. Sorted output is stable. *)
let golden_lines ~file src : (string list, Diag.t list) result =
  Result.map
    (fun hashes ->
      List.concat
        (List.mapi
           (fun i { Canon.decl_hash; named } ->
             Printf.sprintf "%s:%d %s" file i (Hash.to_hex decl_hash)
             :: List.map (fun (n, h) -> Printf.sprintf "%s:%d:%s %s" file i n (Hash.to_hex h)) named)
           hashes))
    (pipeline ~file src)

let corpus_golden_lines ~valid_dir =
  List.concat_map
    (fun file ->
      match golden_lines ~file (read_file (Filename.concat valid_dir file)) with
      | Ok lines -> lines
      | Error ds ->
          failwith
            (Printf.sprintf "%s failed the pipeline: %s" file
               (String.concat "; " (List.map Diag.to_string ds))))
    (jqd_files valid_dir)

(** Elaborated-signature lines for every file in a sigs corpus (plan W3.2 goldens): each line is
    [file:name : scheme]. Files check against a fresh prelude store. *)
let sig_lines ~prelude_dir ~sigs_dir : (string list, Diag.t list) result =
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-sigs-%d-%d" (Unix.getpid ()) (Hashtbl.hash sigs_dir land 0xFFFF))
  in
  let ( let* ) = Result.bind in
  let* store = Store.open_store root in
  let* _ = Prelude.load ~dir:prelude_dir store in
  let* ctx = Check.make_ctx store in
  let* sigs = Prelude.builtin_signatures store in
  Check.register_builtin_signatures ctx sigs;
  let check_file file =
    let path = Filename.concat sigs_dir file in
    let* forms = Reader.parse_string ~file (read_file path) in
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | f :: rest ->
          let* top = Kernel.of_form f in
          let* resolved = Resolve.resolve (Store.names_view store) top in
          let* { Check.names; _ } = Check.check_top ctx resolved in
          let lines =
            List.map
              (fun (n, s) -> Printf.sprintf "%s:%s : %s" file n (Check.show_scheme ctx s))
              names
          in
          let* () =
            match resolved with
            | Kernel.Decl d -> Result.map (fun _ -> ()) (Store.put_decl store d)
            | Kernel.Expr _ -> Ok ()
          in
          go (List.rev_append lines acc) rest
    in
    go [] forms
  in
  let rec all acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | file :: rest ->
        let* lines = check_file file in
        all (lines :: acc) rest
  in
  all [] (jqd_files sigs_dir)

(** Extended pipeline for check-stage invalid corpus cases (W3.3): parse, validate, resolve against
    a REAL prelude store (stub hashes cannot be type-checked), then typecheck. *)
type stage_ext = SParse | SValidate | SResolve | SCheck | SOther

let stage_ext_name = function
  | SParse -> "parse"
  | SValidate -> "validate"
  | SResolve -> "resolve"
  | SCheck -> "check"
  | SOther -> "other"

let check_pipeline ~prelude_dir ~file src : (unit, stage_ext * Diag.t list) result =
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-checkstage-%d-%d" (Unix.getpid ()) (Hashtbl.hash file land 0xFFFF))
  in
  let fail st ds = Error (st, ds) in
  match Store.open_store root with
  | Error ds -> fail SOther ds
  | Ok store -> (
      match Prelude.load ~dir:prelude_dir store with
      | Error ds -> fail SOther ds
      | Ok _ -> (
          match Check.make_ctx store with
          | Error ds -> fail SOther ds
          | Ok ctx -> (
              (match Prelude.builtin_signatures store with
              | Ok sigs -> Check.register_builtin_signatures ctx sigs
              | Error _ -> ());
              match Reader.parse_string ~file src with
              | Error ds -> fail SParse ds
              | Ok forms ->
                  let rec go = function
                    | [] -> Ok ()
                    | f :: rest -> (
                        match Kernel.of_form f with
                        | Error ds -> fail SValidate ds
                        | Ok top -> (
                            match Resolve.resolve (Store.names_view store) top with
                            | Error ds -> fail SResolve ds
                            | Ok resolved -> (
                                match Check.check_top ctx resolved with
                                | Error ds -> fail SCheck ds
                                | Ok _ -> (
                                    match resolved with
                                    | Kernel.Decl d -> (
                                        match Store.put_decl store d with
                                        | Ok _ -> go rest
                                        | Error ds -> fail SOther ds)
                                    | Kernel.Expr _ -> go rest))))
                  in
                  go forms)))

(** A bootstrap source that declares one uniquely named once operation and exercises its clause. *)
let once_diag effect_name operation body =
  Printf.sprintf
    "(defeffect %s () (op %s once () (tref int)))\n\
     (handle (app (var %s)) (ret (pvar x) (var x)) (opclause %s () k %s))"
    effect_name operation operation operation body

(** The W3.7 golden diagnostic battery: 20+ sources covering every checker code (the coverage test
    keys on {!Check.checker_codes}); each renders exactly one diagnostic. [granted] triggers the
    W3.6 manifest check with that effect-name set. *)
let diag_cases : (string * string * string list option) list =
  [
    ("type-mismatch", "(app (var add) (lit 1) (lit \"x\"))", None);
    ( "branch-mismatch",
      "(match (var true) (clause (pcon true) (lit 1)) (clause (pcon false) (lit \"s\")))",
      None );
    ("not-a-function", "(app (lit 3) (lit 1))", None);
    ("app-arity", "(app (lam ((pvar x)) (var x)) (lit 1) (lit 2))", None);
    ( "op-clause-arity",
      "(handle (app (var print) (lit \"x\")) (ret (pvar x) (var x)) (opclause print ((pvar a) \
       (pvar b)) k (app (var k) (tuple))))",
      None );
    ( "resume-arity",
      "(handle (app (var abort)) (ret (pvar x) (var x)) (opclause abort () k (app (var k) (lit 1) \
       (lit 2))))",
      None );
    ( "resume-wrong-type",
      "(handle (app (var print) (lit \"x\")) (ret (pvar x) (var x)) (opclause print ((pvar t)) k \
       (app (var k) (lit 1))))",
      None );
    ("ann-mismatch", "(ann (lit 1) (tref text))", None);
    ( "ann-pure-but-prints",
      "(ann (lam () (app (var print) (lit \"x\"))) (tarrow () (row) (ttuple)))",
      None );
    ( "ann-rigid-escape",
      "(ann (lam ((pvar x)) (lit 1)) (tforall ((tvar a)) () (tarrow ((tvar a)) (row) (tvar a))))",
      None );
    ( "group-annotation-lies",
      "(defterm ((binding liar ((tarrow ((tref int)) (row) (tref text))) (lam ((pvar n)) (var \
       n)))))",
      None );
    ("groupref-outside", "(groupref 5)", None);
    ( "pcon-pattern-arity",
      "(match (app (var some) (lit 1)) (clause (pcon some) (lit 0)) (clause (pwild) (lit 1)))",
      None );
    ( "deftype-arity",
      "(deftype badd ((tvar a)) (con mk (field (tapp (tref option) (tvar a) (tvar a)))))",
      None );
    ("unbound-tyvar", "(deftype badt () (con mk (field (tvar zz))))", None);
    ("op-unbound-var", "(defeffect bade () (op o () (tvar zz)))", None);
    ("nonexhaustive-bool", "(lam ((pvar b)) (match (var b) (clause (pcon true) (lit 1))))", None);
    ( "nonexhaustive-nested",
      "(lam ((pvar o)) (match (var o) (clause (pcon none) (lit 0)) (clause (pcon some (pcon none)) \
       (lit 1)) (clause (pcon some (pcon some (pcon true))) (lit 2))))",
      None );
    ("ungranted-effect", "(app (var print) (lit \"hello\"))", Some []);
    ( "effectful-toplevel-body",
      "(defterm ((binding sneaky () (app (var net.get) (lit \"http://evil.example\")))))",
      None );
    ( "once-double-call",
      once_diag "linear-double" "signal-double"
        "(let nonrec (pwild) (app (var k) (lit 1)) (app (var k) (lit 2)))",
      None );
    ( "once-alias-duplication",
      once_diag "linear-alias" "signal-alias"
        "(let nonrec (pvar k2) (var k) (let nonrec (pwild) (app (var k) (lit 1)) (app (var k2) \
         (lit 2))))",
      None );
    ( "once-lambda-capture",
      once_diag "linear-lambda" "signal-lambda"
        "(let nonrec (pvar f) (lam () (app (var k) (lit 1))) (lit 0))",
      None );
    ( "once-quote-capture",
      once_diag "linear-quote" "signal-quote"
        "(let nonrec (pvar q) (quote (unquote (var k))) (lit 0))",
      None );
    ( "once-constructor-storage",
      once_diag "linear-storage" "signal-storage"
        "(let nonrec (pvar saved) (app (var some) (var k)) (lit 0))",
      None );
    ("once-return", once_diag "linear-return" "signal-return" "(var k)", None);
    ( "redundant-clause",
      "(lam ((pvar b)) (match (var b) (clause (pwild) (lit 0)) (clause (pcon true) (lit 1))))",
      None );
  ]

let diag_surface_cases = [ ("eta-positive", "condition = True\nbool.and-then(True, condition)\n") ]
let diag_strict_recovery_cases = [ ("strict-recovery", "fixture-hole") ]

(** Render the golden diagnostic lines: [name | rendered-diagnostic]. *)
let diag_golden_lines ~prelude_dir : (string list, Diag.t list) result =
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-diags-%d" (Unix.getpid ()))
  in
  let ( let* ) = Result.bind in
  let* store = Store.open_store root in
  let* _ = Prelude.load ~dir:prelude_dir store in
  let* ctx = Check.make_ctx store in
  let* sigs = Prelude.builtin_signatures store in
  Check.register_builtin_signatures ctx sigs;
  let run_case (name, src, granted) =
    let render ds = List.map (fun d -> name ^ " | " ^ Diag.to_string d) ds in
    let* forms = Reader.parse_string ~file:(name ^ ".jqd") src in
    let rec go = function
      | [] -> Ok []
      | f :: rest -> (
          match Kernel.of_form f with
          | Error ds -> Ok (render ds)
          | Ok top -> (
              match Resolve.resolve (Store.names_view store) top with
              | Error ds -> Ok (render ds)
              | Ok resolved -> (
                  match Check.check_top ctx resolved with
                  | Error ds -> Ok (render ds)
                  | Ok { Check.warnings = _ :: _ as ws; _ } -> Ok (render ws)
                  | Ok { Check.row; _ } -> (
                      let continue () =
                        match resolved with
                        | Kernel.Expr _ -> go rest
                        | Kernel.Decl declaration -> (
                            match Store.put_decl store declaration with
                            | Ok _ -> go rest
                            | Error ds -> Ok (render ds))
                      in
                      match (granted, row) with
                      | Some names, Some r -> (
                          let g =
                            List.filter_map
                              (fun n ->
                                match Store.lookup_name store n with
                                | Some { Resolve.hash; kind = Resolve.KEffect } -> Some hash
                                | _ -> None)
                              names
                          in
                          match
                            Check.manifest_errors ctx ~grantable:Prelude.grantable_names ~granted:g
                              r
                          with
                          | [] -> continue ()
                          | ds -> Ok (render ds))
                      | _ -> continue ()))))
    in
    go forms
  in
  let run_surface_case (name, src) =
    let render ds = List.map (fun d -> name ^ " | " ^ Diag.to_string d) ds in
    let* tops = Surface_parse.strict (Surface_parse.recover_string ~file:(name ^ ".jac") src) in
    let* lowered = Surface_lower.lower_tops tops in
    let rec go = function
      | [] -> Ok []
      | top :: rest -> (
          let* resolved = Resolve.resolve (Store.names_view store) top in
          match Check.check_top ctx resolved with
          | Error ds -> Ok (render ds)
          | Ok _ -> (
              match resolved with
              | Kernel.Decl declaration ->
                  let* _ = Store.put_decl store declaration in
                  go rest
              | Kernel.Expr _ -> go rest))
    in
    go lowered
  in
  let run_strict_recovery_case (name, hole) =
    let meta = Meta.with_surface_hole hole Meta.empty in
    let expression = Kernel.{ it = Lit (LInt 0); meta } in
    match Check.check_top ctx (Kernel.Expr expression) with
    | Error ds -> Ok (List.map (fun d -> name ^ " | " ^ Diag.to_string d) ds)
    | Ok _ -> Ok []
  in
  let rec all acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | c :: rest ->
        let* lines = run_case c in
        all (lines :: acc) rest
  in
  let* bootstrap = all [] diag_cases in
  let rec collect run acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | case :: rest ->
        let* lines = run case in
        collect run (lines :: acc) rest
  in
  let* surface = collect run_surface_case [] diag_surface_cases in
  let* strict_recovery = collect run_strict_recovery_case [] diag_strict_recovery_cases in
  Ok (bootstrap @ surface @ strict_recovery)

(* --- SL.9: the rings manifest, the layering audit, and the ring-0 freeze --- *)

(** [parse_rings path] reads a rings manifest: `name ring` lines, `#` comments. *)
let parse_rings path : (string * int) list =
  let ic = open_in path in
  let rec go acc =
    match input_line ic with
    | exception End_of_file ->
        close_in ic;
        List.rev acc
    | line -> (
        let line = String.trim line in
        if line = "" || line.[0] = '#' then go acc
        else
          match String.split_on_char ' ' line with
          | [ name; ring ] -> go ((name, int_of_string ring) :: acc)
          | _ -> failwith ("bad rings.manifest line: " ^ line))
  in
  go []

(** [ring_violations store rings] walks every named declaration's deps (Store.deps over the content
    graph) and reports each edge whose target sits at a HIGHER ring than the source — the "rings are
    literal" claim made executable. Also reports manifest gaps (names in the store index missing
    from the manifest) so the file cannot silently rot. *)
let ring_violations (store : Store.t) (rings : (string * int) list) : string list =
  let ring_of n = List.assoc_opt n rings in
  (* member hash -> the names bound to it (via each binding's own hash) *)
  let names_of_hash h =
    List.filter_map
      (fun (n, { Resolve.hash; _ }) -> if Hash.equal hash h then Some n else None)
      (Store.names store)
  in
  let violations = ref [] in
  let missing = ref [] in
  List.iter
    (fun (name, { Resolve.hash; _ }) ->
      match ring_of name with
      | None -> if not (List.mem name !missing) then missing := name :: !missing
      | Some own -> (
          match Store.locate store hash with
          | Error _ -> ()
          | Ok { Store.decl_hash; _ } -> (
              match Store.deps store decl_hash with
              | Error _ -> ()
              | Ok dep_hashes ->
                  List.iter
                    (fun dh ->
                      (* one hash may carry several names (content addressing dedups
                         identical bodies, e.g. enum.append = list.append); the
                         definition lives at the LOWEST ring any of its names claims *)
                      let dep =
                        List.fold_left
                          (fun best dep_name ->
                            match (ring_of dep_name, best) with
                            | Some r, Some (_, br) when r < br -> Some (dep_name, r)
                            | Some r, None -> Some (dep_name, r)
                            | _ -> best)
                          None (names_of_hash dh)
                      in
                      match dep with
                      | Some (dep_name, dep_ring) when dep_ring > own ->
                          violations :=
                            Printf.sprintf "%s (ring %d) -> %s (ring %d)" name own dep_name dep_ring
                            :: !violations
                      | _ -> ())
                    dep_hashes)))
    (Store.names store);
  List.sort_uniq compare
    (!violations @ List.map (fun n -> Printf.sprintf "missing from rings.manifest: %s" n) !missing)

(** [freeze_lines ~prelude_dir ~manifest] renders the ring-0 freeze artifact: every ring-0 name with
    its elaborated signature (terms), or its kind (types/constructors). Names, not hashes: the
    freeze pins the API surface. *)
let freeze_lines ~prelude_dir ~manifest : (string list, Diag.t list) result =
  let ( let* ) = Result.bind in
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-freeze-%d" (Unix.getpid ()))
  in
  let* store = Store.open_store root in
  let* _ = Prelude.load ~dir:prelude_dir store in
  let* ctx = Check.make_ctx store in
  let* sigs = Prelude.builtin_signatures store in
  Check.register_builtin_signatures ctx sigs;
  let rings = parse_rings manifest in
  let ring0 = List.filter_map (fun (n, r) -> if r = 0 then Some n else None) rings in
  let lines =
    List.concat_map
      (fun name ->
        (* one line per (name, kind): a name bound as both term and type (eq) pins BOTH *)
        List.map
          (fun { Resolve.hash; kind } ->
            match kind with
            | Resolve.KTerm ->
                Printf.sprintf "%s : %s" name (Check.show_scheme ctx (Check.term_scheme ctx hash))
            | Resolve.KType -> Printf.sprintf "type %s" name
            | Resolve.KCon -> Printf.sprintf "con %s" name
            | Resolve.KOp -> Printf.sprintf "op %s" name
            | Resolve.KEffect -> Printf.sprintf "effect %s" name)
          (Store.lookup_all store name))
      (List.sort_uniq String.compare ring0)
  in
  Ok lines
