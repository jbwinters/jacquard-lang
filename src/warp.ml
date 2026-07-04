(** Warp, the testing layer (plan W6.1–W6.3, W6.8).

    Discovery is by CHECKED TYPE (decision D12): a store term whose elaborated type is [test] is a
    hermetic test, [world-test] a world test; names are display only. The hermetic lane runs each
    thunk under the in-language [test.run] handler via {!Eval.call} (the M1 entry point built for
    exactly this); the world lane runs only tests whose row the CLI's grants cover, refusing the
    rest by name.

    The result cache (W6.3) is an honest lookup table over the Merkle discipline: a Case's key is
    its member hash (which covers its transitive references), a Prop's key adds mode/samples/seed
    from day one, WorldTests are never cached. Every key includes {!version} — native drivers live
    in no hash, so the explicit tag re-keys the world when they change. Entries are canonical
    printed forms; a corrupt entry is ignored and rerun.

    Coverage (W6.8) is the complement of the union of per-test {!Eval.ctx} coverage sets —
    definition-level, from the hash discipline alone; cache entries record their coverage so a
    fully-cached run reports the same complement as a cold one. *)

let version = "warp-v1"

type verdict = Pass of int | Fail of { soft : string list; hard : string option } | NoChecks

type outcome = {
  display : string;
  verdict : verdict option;  (** None = skipped (prop pending) or refused *)
  note : string option;  (** SKIP/REFUSED annotation *)
  coverage : Hash.t list;
  cached : bool;
}

type discovered = Hermetic of string * Hash.t | World of string * Hash.t

(* --- discovery (W6.2) --- *)

let discover (store : Store.t) (cctx : Check.ctx) : discovered list =
  let ty_hash name =
    match Store.lookup_kind store name Resolve.KType with
    | Some { Resolve.hash; _ } -> Some hash
    | None -> None
  in
  match (ty_hash "test", ty_hash "world-test") with
  | Some test_h, Some world_h ->
      List.filter_map
        (fun (name, { Resolve.hash; kind }) ->
          if kind <> Resolve.KTerm then None
          else
            match Types.repr (Check.term_scheme cctx hash).Types.ty with
            | exception Check.Err _ -> None (* unschemable => not a test *)
            | Types.TCon (h, []) when Hash.equal h test_h -> Some (Hermetic (name, hash))
            | Types.TCon (h, []) when Hash.equal h world_h -> Some (World (name, hash))
            | _ -> None)
        (List.sort (fun (a, _) (b, _) -> String.compare a b) (Store.names store))
  | _ -> []

(* --- running (W6.2) --- *)

let value_of ctx (h : Hash.t) : (Value.t, Runtime_err.t) result =
  Eval.run_expr ctx { Kernel.it = Kernel.Ref (h, Kernel.Term); meta = Meta.empty }

(* decompose a runtime report; the shape is pinned by prelude/15-warp.wft *)
let verdict_of_report (v : Value.t) : (verdict, string) result =
  let rec entries acc = function
    | Value.VCon { name = "nil"; _ } -> Ok (List.rev acc)
    | Value.VCon
        {
          name = "cons";
          args = [ Value.VTuple [ Value.VText label; Value.VCon { name = ok; _ } ]; rest ];
          _;
        } ->
        entries ((label, ok = "true") :: acc) rest
    | v -> Error (Printf.sprintf "malformed report entries: %s" (Value.show v))
  in
  match v with
  | Value.VCon { name = "mk-report"; args = [ es; hard ]; _ } -> (
      match entries [] es with
      | Error e -> Error e
      | Ok es -> (
          let soft = List.filter_map (fun (l, ok) -> if ok then None else Some l) es in
          match hard with
          | Value.VCon { name = "some"; args = [ Value.VText msg ]; _ } ->
              Ok (Fail { soft; hard = Some msg })
          | Value.VCon { name = "none"; _ } ->
              if soft <> [] then Ok (Fail { soft; hard = None })
              else if es = [] then Ok NoChecks
              else Ok (Pass (List.length es))
          | v -> Error (Printf.sprintf "malformed report hard field: %s" (Value.show v))))
  | v -> Error (Printf.sprintf "not a report: %s" (Value.show v))

(* Run one thunk under test.run, collecting its per-test coverage set. A runtime crash
   is a FAILING verdict, not a runner abort: one broken test must not blind the suite.
   NOTE (coverage approximation, documented): ctx.memo persists across tests, so a
   computed CONSTANT's transitive deps mark only the first test that forces it; later
   tests record the constant itself but not what it touched. Safe direction only — a
   warm complement can over-report "uncovered", never falsely claim covered. *)
let run_thunk ctx ~test_run (thunk : Value.t) : (verdict * Hash.t list, string) result =
  let outer = ctx.Eval.coverage in
  let mine_tbl = Hashtbl.create 64 in
  ctx.Eval.coverage <- mine_tbl;
  let result =
    Fun.protect
      ~finally:(fun () ->
        Hashtbl.iter (fun h () -> Hashtbl.replace outer h ()) mine_tbl;
        ctx.Eval.coverage <- outer)
      (fun () -> Eval.call ctx test_run [ thunk ])
  in
  let mine = Hashtbl.fold (fun h () acc -> h :: acc) mine_tbl [] in
  match result with
  | Ok report -> Result.map (fun v -> (v, mine)) (verdict_of_report report)
  | Error e ->
      Ok (Fail { soft = []; hard = Some ("runtime error: " ^ Runtime_err.to_string e) }, mine)

(* the world row a wcase thunk needs, read from the constructor's own scheme *)
let world_required (cctx : Check.ctx) (store : Store.t) : Hash.t list =
  match Store.lookup_kind store "wcase" Resolve.KCon with
  | None -> []
  | Some { Resolve.hash; _ } -> (
      match Types.repr (Check.con_scheme cctx hash).Types.ty with
      | Types.TArrow ([ _label; thunk_ty ], _, _) -> (
          match Types.repr thunk_ty with
          | Types.TArrow ([], row, _) ->
              let row = Types.repr_row row in
              let check_h =
                match Store.lookup_kind store "check" Resolve.KEffect with
                | Some { Resolve.hash; _ } -> Some hash
                | None -> None
              in
              List.filter
                (fun h -> match check_h with Some c -> not (Hash.equal h c) | None -> true)
                row.Types.effects
          | _ -> [])
      | _ -> [])

(* --- the cache (W6.3) --- *)

let cache_key_string = function
  | Hermetic (_, h) -> Printf.sprintf "%s|case|%s" version (Hash.to_hex h)
  | World _ -> invalid_arg "world tests are never cached"

(* prop keys carry mode/samples/seed from day one so the format never migrates *)
let prop_key_string ~member ~mode ~samples ~seed =
  Printf.sprintf "%s|prop|%s|mode=%s|samples=%d|seed=%d" version (Hash.to_hex member) mode samples
    seed

let _ = prop_key_string (* W6.4 consumes this; referenced so the format is honest now *)

let verdict_form (verdict : verdict) : Form.t =
  match verdict with
  | Pass n -> Form.form "pass" [ Form.Int n ]
  | NoChecks -> Form.form "no-checks" []
  | Fail { soft; hard } ->
      Form.form "fail"
        (Form.F (Form.form "soft" (List.map (fun s -> Form.Text s) soft))
        :: (match hard with Some h -> [ Form.F (Form.form "hard" [ Form.Text h ]) ] | None -> []))

(* one entry per DISCOVERED test: a group's entry (keyed by the group hash, which
   Merkle-covers every member) holds one outcome per member, display included, so a
   cached hit renders exactly what the cold run rendered *)
let entry_form ~key ~(outcomes : (string * verdict * Hash.t list) list) : Form.t =
  Form.form "test-cache-entry"
    (Form.F (Form.form "key" [ Form.Text key ])
    :: List.map
         (fun (display, verdict, coverage) ->
           Form.F
             (Form.form "outcome"
                [
                  Form.F (Form.form "display" [ Form.Text display ]);
                  Form.F (Form.form "verdict" [ Form.F (verdict_form verdict) ]);
                  Form.F (Form.form "coverage" (List.map (fun h -> Form.Hash h) coverage));
                ]))
         outcomes)

let verdict_of_form (v : Form.t) : verdict option =
  match v with
  | { Form.head = "pass"; args = [ Form.Int n ]; _ } -> Some (Pass n)
  | { Form.head = "no-checks"; args = []; _ } -> Some NoChecks
  | { Form.head = "fail"; args = Form.F { Form.head = "soft"; args = soft; _ } :: rest; _ } ->
      let soft = List.filter_map (function Form.Text s -> Some s | _ -> None) soft in
      let hard =
        match rest with
        | [ Form.F { Form.head = "hard"; args = [ Form.Text h ]; _ } ] -> Some h
        | _ -> None
      in
      Some (Fail { soft; hard })
  | _ -> None

let entry_of_form (f : Form.t) : (string * (string * verdict * Hash.t list) list) option =
  match f with
  | {
   Form.head = "test-cache-entry";
   args = Form.F { Form.head = "key"; args = [ Form.Text key ]; _ } :: rest;
   _;
  } ->
      let outcome = function
        | Form.F
            {
              Form.head = "outcome";
              args =
                [
                  Form.F { Form.head = "display"; args = [ Form.Text display ]; _ };
                  Form.F { Form.head = "verdict"; args = [ Form.F v ]; _ };
                  Form.F { Form.head = "coverage"; args = cov; _ };
                ];
              _;
            } ->
            Option.map
              (fun verdict ->
                ( display,
                  verdict,
                  List.filter_map (function Form.Hash h -> Some h | _ -> None) cov ))
              (verdict_of_form v)
        | _ -> None
      in
      let outcomes = List.map outcome rest in
      if List.exists (( = ) None) outcomes then None else Some (key, List.filter_map Fun.id outcomes)
  | _ -> None

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let cache_lookup ~cache_dir key : (string * verdict * Hash.t list) list option =
  match cache_dir with
  | None -> None
  | Some dir -> (
      let path = Filename.concat dir (Hash.to_hex (Hash.of_string key) ^ ".wft") in
      match read_file path with
      | exception Sys_error _ -> None (* absent or unreadable: rerun *)
      | src -> (
          match Reader.parse_one ~file:path src with
          | Ok f -> (
              match entry_of_form f with
              | Some (k, outcomes) when k = key && outcomes <> [] -> Some outcomes
              | _ -> None (* corrupt or mismatched: ignore and rerun *))
          | Error _ -> None))

let cache_store ~cache_dir key outcomes : unit =
  match cache_dir with
  | None -> ()
  | Some dir -> (
      try
        if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
        let path = Filename.concat dir (Hash.to_hex (Hash.of_string key) ^ ".wft") in
        let oc = open_out_bin path in
        output_string oc (Printer.print (entry_form ~key ~outcomes) ^ "\n");
        close_out oc
      with Sys_error m -> Printf.eprintf "test-cache unavailable (%s)\n%!" m)

(* --- the runner --- *)

type totals = {
  mutable passed : int;
  mutable failed : int;
  mutable skipped : int;
  mutable refused : int;
  mutable hits : int;
  mutable ran : int;
}

(* walk one discovered test VALUE, recursing into groups *)
let rec run_value ctx ~test_run ~display (v : Value.t) : (outcome list, string) result =
  match v with
  | Value.VCon { name = "case"; args = [ Value.VText label; thunk ]; _ } -> (
      let display = display ^ "/" ^ label in
      match run_thunk ctx ~test_run thunk with
      | Ok (verdict, coverage) ->
          Ok [ { display; verdict = Some verdict; note = None; coverage; cached = false } ]
      | Error e -> Error (Printf.sprintf "%s: %s" display e))
  | Value.VCon { name = "prop"; args = [ Value.VText label; _ ]; _ } ->
      Ok
        [
          {
            display = display ^ "/" ^ label;
            verdict = None;
            note = Some "prop: driver pending (W6.4)";
            coverage = [];
            cached = false;
          };
        ]
  | Value.VCon { name = "group"; args = [ Value.VText label; tests ]; _ } ->
      let rec walk acc = function
        | Value.VCon { name = "nil"; _ } -> Ok (List.concat (List.rev acc))
        | Value.VCon { name = "cons"; args = [ t; rest ]; _ } -> (
            match run_value ctx ~test_run ~display:(display ^ "/" ^ label) t with
            | Ok os -> walk (os :: acc) rest
            | Error e -> Error e)
        | v -> Error (Printf.sprintf "malformed group: %s" (Value.show v))
      in
      walk [] tests
  | Value.VCon { name = "wcase"; args = [ Value.VText label; thunk ]; _ } -> (
      (* world lane: the caller already verified grants; never cached *)
      let display = display ^ "/" ^ label in
      match run_thunk ctx ~test_run thunk with
      | Ok (verdict, coverage) ->
          Ok [ { display; verdict = Some verdict; note = None; coverage; cached = false } ]
      | Error e -> Error (Printf.sprintf "%s: %s" display e))
  | v -> Error (Printf.sprintf "not a test value: %s" (Value.show v))

(** [run_discovered ctx ~test_run ~cache_dir ~granted d] executes one discovered test. Hermetic
    Cases consult the cache by member hash; groups cache as a unit under the group's member hash
    (its hash covers the members). World tests check grant coverage. *)
let run_discovered ctx (cctx : Check.ctx) ~test_run ~cache_dir ~(granted : Hash.t list)
    (d : discovered) : (outcome list, string) result =
  match d with
  | Hermetic (name, h) -> (
      let key = cache_key_string d in
      match cache_lookup ~cache_dir key with
      | Some stored ->
          Ok
            (List.map
               (fun (display, verdict, coverage) ->
                 { display; verdict = Some verdict; note = None; coverage; cached = true })
               stored)
      | None -> (
          match value_of ctx h with
          | Error e -> Error (Printf.sprintf "%s: %s" name (Runtime_err.to_string e))
          | Ok v -> (
              match run_value ctx ~test_run ~display:name v with
              | Error e -> Error e
              | Ok outcomes ->
                  (* every EXECUTED outcome caches, display included, keyed by this
                     test's member hash (a group hash Merkle-covers its members); props
                     inside (verdict = None) block the entry — they have no result yet *)
                  if List.for_all (fun o -> o.verdict <> None) outcomes && outcomes <> [] then
                    cache_store ~cache_dir key
                      (List.map (fun o -> (o.display, Option.get o.verdict, o.coverage)) outcomes);
                  Ok outcomes)))
  | World (name, h) ->
      let required = world_required cctx ctx.Eval.store in
      let missing = List.filter (fun r -> not (List.exists (Hash.equal r) granted)) required in
      if missing <> [] then
        let names =
          List.filter_map
            (fun mh ->
              List.find_map
                (fun (n, { Resolve.hash; kind }) ->
                  if kind = Resolve.KEffect && Hash.equal hash mh then Some n else None)
                (Store.names ctx.Eval.store))
            missing
        in
        Ok
          [
            {
              display = name;
              verdict = None;
              note = Some (Printf.sprintf "refused: requires --allow %s" (String.concat "," names));
              coverage = [];
              cached = false;
            };
          ]
      else
        Result.bind
          (Result.map_error Runtime_err.to_string (value_of ctx h))
          (fun v -> run_value ctx ~test_run ~display:name v)

(* --- rendering --- *)

let render_outcome (t : totals) (o : outcome) : string list =
  match (o.verdict, o.note) with
  | Some (Pass n), _ ->
      t.passed <- t.passed + 1;
      if o.cached then t.hits <- t.hits + 1 else t.ran <- t.ran + 1;
      [
        Printf.sprintf "PASS %s (%d check%s)%s" o.display n
          (if n = 1 then "" else "s")
          (if o.cached then " [cached]" else "");
      ]
  | Some NoChecks, _ ->
      t.passed <- t.passed + 1;
      if o.cached then t.hits <- t.hits + 1 else t.ran <- t.ran + 1;
      [
        Printf.sprintf "WARN %s: made no checks%s" o.display (if o.cached then " [cached]" else "");
      ]
  | Some (Fail { soft; hard }), _ -> (
      t.failed <- t.failed + 1;
      if o.cached then t.hits <- t.hits + 1 else t.ran <- t.ran + 1;
      Printf.sprintf "FAIL %s%s" o.display (if o.cached then " [cached]" else "")
      :: List.map (fun l -> "  - " ^ l) soft
      @ match hard with Some h -> [ "  ! " ^ h ] | None -> [])
  | None, Some note when String.length note >= 7 && String.sub note 0 7 = "refused" ->
      t.refused <- t.refused + 1;
      [ Printf.sprintf "REFUSED %s: %s" o.display (String.sub note 9 (String.length note - 9)) ]
  | None, note ->
      t.skipped <- t.skipped + 1;
      [ Printf.sprintf "SKIP %s (%s)" o.display (Option.value note ~default:"skipped") ]

(** [parse_rings path] reads a rings manifest when one ships with the prelude, for ring-grouped
    coverage rendering; absent or malformed manifests degrade to no grouping. *)
let parse_rings path : (string * int) list =
  match open_in path with
  | exception Sys_error _ -> []
  | ic ->
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
              | [ name; ring ] -> (
                  match int_of_string_opt ring with
                  | Some r -> go ((name, r) :: acc)
                  | None -> go acc)
              | _ -> go acc)
      in
      go []

(** [coverage_report store ~rings ~tests union] renders the complement: every KTerm name whose
    member hash was never loaded, minus the tests themselves, grouped by ring when the manifest maps
    the name. *)
let coverage_report (store : Store.t) ~(rings : (string * int) list) ~(tests : Hash.t list)
    (union : (Hash.t, unit) Hashtbl.t) : string list =
  let all =
    List.filter_map
      (fun (n, { Resolve.hash; kind }) ->
        if kind = Resolve.KTerm && not (List.exists (Hash.equal hash) tests) then Some (n, hash)
        else None)
      (Store.names store)
  in
  let covered, uncovered =
    List.partition (fun (_, h) -> Hashtbl.mem union h) (List.sort_uniq compare all)
  in
  let ring_of n = List.assoc_opt n rings in
  let annotated =
    List.map (fun (n, _) -> (ring_of n, n)) uncovered
    |> List.sort (fun (ra, na) (rb, nb) -> match compare ra rb with 0 -> compare na nb | c -> c)
  in
  Printf.sprintf "coverage: %d of %d definitions executed" (List.length covered) (List.length all)
  :: List.map
       (fun (r, n) ->
         match r with
         | Some r -> Printf.sprintf "  uncovered %s (ring %d)" n r
         | None -> Printf.sprintf "  uncovered %s" n)
       annotated
