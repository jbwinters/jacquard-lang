(** The `jacquard build` driver (docs/native-plan.md, task 67): reachability over the store DAG,
    lowering, per-declaration C units cached by content, and the system-toolchain compile+link.
    clang is required in v1 (musttail); the cache directory carries the emitter version, so bumping
    [emitter_version] invalidates every unit. *)

open Jacquard

let emitter_version = "v1"

(** The implemented intrinsic surface (docs/native-intrinsics.md). Everything else a program reaches
    is refused by lowering with the builtin's name. *)
let intrinsics : (string * int) list =
  [
    ("add", 2);
    ("sub", 2);
    ("mul", 2);
    ("div", 2);
    ("mod", 2);
    ("eq", 2);
    ("lt", 2);
    ("add-real", 2);
    ("sub-real", 2);
    ("mul-real", 2);
    ("div-real", 2);
    ("lt-real", 2);
    ("text.length", 1);
    ("text.concat", 2);
    ("int-compare", 2);
    ("text-compare", 2);
  ]

(* ------------------------------------------------------------------ *)
(* Store discovery                                                     *)
(* ------------------------------------------------------------------ *)

(* A builtin marker body is (quote (builtin-marker <name>)). *)
let builtin_marker_name (value : Kernel.expr) : string option =
  match value.Kernel.it with
  | Kernel.Quote { Form.head = "builtin-marker"; args = [ Form.Sym name ]; _ } -> Some name
  | _ -> None

type discovery = {
  builtin_names : (Hash.t, string) Hashtbl.t;
  member_arity : (Hash.t, int) Hashtbl.t;
  member_binding : (Hash.t, string * Kernel.expr * Hash.t) Hashtbl.t;
      (** member -> (name, body, owning decl hash) *)
}

let discover (store : Store.t) : discovery =
  let d =
    {
      builtin_names = Hashtbl.create 64;
      member_arity = Hashtbl.create 256;
      member_binding = Hashtbl.create 256;
    }
  in
  List.iter
    (fun ((name, entry) : string * Resolve.entry) ->
      if entry.Resolve.kind = Resolve.KTerm then
        match Store.locate store entry.Resolve.hash with
        | Ok
            {
              Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ };
              role = Store.Member i;
              decl_hash;
            } -> (
            match List.nth_opt bindings i with
            | Some b -> (
                Hashtbl.replace d.member_binding entry.Resolve.hash (name, b.Kernel.value, decl_hash);
                match builtin_marker_name b.Kernel.value with
                | Some bname -> Hashtbl.replace d.builtin_names entry.Resolve.hash bname
                | None -> (
                    match b.Kernel.value.Kernel.it with
                    | Kernel.Lam (params, _) ->
                        Hashtbl.replace d.member_arity entry.Resolve.hash (List.length params)
                    | _ -> ()))
            | None -> ())
        | _ -> ())
    store.Store.names;
  d

(* ------------------------------------------------------------------ *)
(* Program compilation                                                 *)
(* ------------------------------------------------------------------ *)

type outcome = { prog : Emit.program; refusals : Compile.refusal list }

let compile_program (store : Store.t) (d : discovery) (tops_src : (Kernel.expr * string list) list)
    : outcome =
  let itbl = Hashtbl.create 16 in
  List.iter (fun (n, a) -> Hashtbl.replace itbl n a) intrinsics;
  let refusals = ref [] in
  let members : (Hash.t, Compile.compiled_member) Hashtbl.t = Hashtbl.create 64 in
  let queue = Queue.create () in
  let seen = Hashtbl.create 64 in
  let enqueue h =
    if (not (Hashtbl.mem seen h)) && not (Hashtbl.mem d.builtin_names h) then begin
      Hashtbl.replace seen h ();
      Queue.add h queue
    end
  in
  (* arity cap: enforced during lowering via the same refusal channel *)
  let tops =
    List.mapi
      (fun i (e, warnings) ->
        match
          Compile.lower_top ~store ~intrinsics:itbl ~builtin_names:d.builtin_names
            ~member_arity:d.member_arity ~index:i e
        with
        | body, lifted, deps, cons ->
            List.iter enqueue deps;
            (body, lifted, warnings, cons)
        | exception Compile.Refused r ->
            refusals := r :: !refusals;
            (Compile.Ret (Compile.AInt 0), [], warnings, []))
      tops_src
  in
  while not (Queue.is_empty queue) do
    let h = Queue.pop queue in
    match Hashtbl.find_opt d.member_binding h with
    | None ->
        refusals :=
          { Compile.where = Hash.to_hex h; what = "reachable member is not a term binding" }
          :: !refusals
    | Some (name, value, _) -> (
        match
          Compile.lower_member ~store ~intrinsics:itbl ~builtin_names:d.builtin_names
            ~member_arity:d.member_arity ~name h value
        with
        | cm ->
            Hashtbl.replace members h cm;
            List.iter enqueue cm.Compile.deps
        | exception Compile.Refused r -> refusals := r :: !refusals)
  done;
  (* constructor table: dense type ids per owning declaration *)
  let cons : (Hash.t, Emit.conref) Hashtbl.t = Hashtbl.create 32 in
  let type_ids : (Hash.t, int) Hashtbl.t = Hashtbl.create 8 in
  let next_type = ref 0 in
  let note_con h =
    if not (Hashtbl.mem cons h) then
      match Store.locate store h with
      | Ok
          {
            Store.decl = { Kernel.it = Kernel.DefType { cons = cs; _ }; _ };
            role = Store.Constructor i;
            decl_hash;
          } -> (
          match List.nth_opt cs i with
          | Some { Kernel.con_name; fields; _ } ->
              let tid =
                match Hashtbl.find_opt type_ids decl_hash with
                | Some t -> t
                | None ->
                    incr next_type;
                    Hashtbl.replace type_ids decl_hash !next_type;
                    !next_type
              in
              Hashtbl.replace cons h
                {
                  Emit.chash = h;
                  cname = con_name;
                  carity = List.length fields;
                  ctype_id = tid;
                  cordinal = i;
                }
          | None -> ())
      | _ -> ()
  in
  Hashtbl.iter
    (fun _ (cm : Compile.compiled_member) -> List.iter note_con cm.Compile.cons_used)
    members;
  List.iter (fun (_, _, _, cs) -> List.iter note_con cs) tops;
  (* true/false always exist: intrinsics return them *)
  (match Store.lookup_kind store "true" Resolve.KCon with
  | Some e -> note_con e.Resolve.hash
  | None -> ());
  (match Store.lookup_kind store "false" Resolve.KCon with
  | Some e -> note_con e.Resolve.hash
  | None -> ());
  List.iter
    (fun n ->
      match Store.lookup_kind store n Resolve.KCon with
      | Some e -> note_con e.Resolve.hash
      | None -> ())
    [ "less"; "equal"; "greater" ];
  (* init order: const members topologically by their const-member deps *)
  let member_list = Hashtbl.fold (fun _ cm acc -> cm :: acc) members [] in
  let member_list =
    List.sort
      (fun (a : Compile.compiled_member) b -> compare (Hash.to_hex a.member) (Hash.to_hex b.member))
      member_list
  in
  let is_const h =
    match Hashtbl.find_opt members h with Some cm -> cm.Compile.const_body <> None | None -> false
  in
  let visited = Hashtbl.create 16 in
  let order = ref [] in
  let rec visit h =
    if is_const h && not (Hashtbl.mem visited h) then begin
      Hashtbl.replace visited h ();
      (match Hashtbl.find_opt members h with
      | Some cm -> List.iter visit cm.Compile.deps
      | None -> ());
      order := h :: !order
    end
  in
  List.iter (fun (cm : Compile.compiled_member) -> visit cm.Compile.member) member_list;
  let prog =
    {
      Emit.members = member_list;
      member_arity = d.member_arity;
      builtin_names =
        (let t = Hashtbl.create 16 in
         Hashtbl.iter (fun h n -> if Hashtbl.mem itbl n then Hashtbl.replace t h n) d.builtin_names;
         t);
      cons;
      tops = List.map (fun (b, l, w, _) -> (b, l, w)) tops;
      init_order = List.rev !order;
    }
  in
  { prog; refusals = List.rev !refusals }

(* ------------------------------------------------------------------ *)
(* Toolchain                                                           *)
(* ------------------------------------------------------------------ *)

let run_cmd_quiet (cmd : string) : int = Sys.command cmd
let quote = Filename.quote

let require_clang () : (string, string) result =
  let cc = match Sys.getenv_opt "CC" with Some c -> c | None -> "cc" in
  let ic = Unix.open_process_in (quote cc ^ " --version 2>/dev/null") in
  let first = try input_line ic with End_of_file -> "" in
  ignore (Unix.close_process_in ic);
  let contains s sub =
    let n = String.length sub in
    let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
    go 0
  in
  if contains first "clang" then Ok cc
  else
    Error
      (Printf.sprintf "jacquard build requires clang in v1 (musttail); CC resolves to `%s` (%s)" cc
         (if first = "" then "not found" else first))

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let write_if_changed path content : bool =
  let same = Sys.file_exists path && read_file path = content in
  if not same then begin
    let oc = open_out_bin path in
    output_string oc content;
    close_out oc
  end;
  not same

let mkdir_p dir =
  let rec go d =
    if not (Sys.file_exists d) then begin
      go (Filename.dirname d);
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  go dir

(** Compile and link. Returns the number of program units recompiled (the cram-pinned summary counts
    these; runtime objects do not count). *)
let link_program ~cc ~cache ~runtime_dir ~(units : (string * string) list) ~(main_c : string) ~out :
    (int, string) result =
  mkdir_p cache;
  let compiled = ref 0 in
  let objs = ref [] in
  let compile_c ~count name content =
    let c_path = Filename.concat cache (name ^ ".c") in
    let o_path = Filename.concat cache (name ^ ".o") in
    let changed = write_if_changed c_path content in
    let need = changed || not (Sys.file_exists o_path) in
    if need then begin
      if count then incr compiled;
      let extra = match Sys.getenv_opt "JACQUARD_NATIVE_CFLAGS" with Some f -> f | None -> "" in
      let cmd =
        Printf.sprintf "%s -std=c11 -O2 -Wall %s -I %s -c %s -o %s" (quote cc) extra
          (quote runtime_dir) (quote c_path) (quote o_path)
      in
      if run_cmd_quiet cmd <> 0 then failwith ("C compilation failed: " ^ c_path)
    end;
    objs := o_path :: !objs
  in
  (* runtime objects: recompiled when their source bytes change (content copied into the cache
     so staleness is exact) *)
  let runtime_srcs =
    Sys.readdir runtime_dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".c")
    |> List.sort compare
  in
  match
    List.iter
      (fun f ->
        let content = read_file (Filename.concat runtime_dir f) in
        compile_c ~count:false ("jqrt_" ^ Filename.remove_extension f) content)
      runtime_srcs;
    List.iter (fun (name, content) -> compile_c ~count:true name content) units;
    compile_c ~count:true "prog_main" main_c
  with
  | () ->
      let extra = match Sys.getenv_opt "JACQUARD_NATIVE_CFLAGS" with Some f -> f | None -> "" in
      let cmd =
        Printf.sprintf "%s -O2 %s %s -o %s -lm -lpthread" (quote cc) extra
          (String.concat " " (List.map quote (List.rev !objs)))
          (quote out)
      in
      if run_cmd_quiet cmd <> 0 then Error "linking failed" else Ok !compiled
  | exception Failure m -> Error m

(* ------------------------------------------------------------------ *)
(* Entry                                                               *)
(* ------------------------------------------------------------------ *)

let runtime_dir_of ~prelude_dir =
  match Sys.getenv_opt "JACQUARD_RUNTIME" with
  | Some d -> d
  | None -> Filename.concat (Filename.dirname prelude_dir) "runtime"

(** [build ~store ~tops ~prelude_dir ~out] compiles the checked top-level expressions and every
    reachable declaration to a standalone binary at [out]. *)
let build ~(store : Store.t) ~(tops : (Kernel.expr * string list) list) ~prelude_dir ~out :
    (int, [ `Refused of Compile.refusal list | `Toolchain of string ]) result =
  let d = discover store in
  let { prog; refusals } = compile_program store d tops in
  (* Perceus (task 68): precise ownership unless the differential lever turns it off *)
  let precise = Sys.getenv_opt "JACQUARD_PERCEUS" <> Some "off" in
  let prog =
    if not precise then prog
    else
      {
        prog with
        Emit.members =
          List.map
            (fun (cm : Compile.compiled_member) ->
              {
                cm with
                Compile.main_fn = Option.map Perceus.fn cm.Compile.main_fn;
                const_body = Option.map (Perceus.walk Perceus.SSet.empty) cm.Compile.const_body;
                lifted = List.map Perceus.fn cm.Compile.lifted;
              })
            prog.Emit.members;
        tops =
          List.map
            (fun (body, lifted, warnings) ->
              (Perceus.walk Perceus.SSet.empty body, List.map Perceus.fn lifted, warnings))
            prog.Emit.tops;
      }
  in
  if refusals <> [] then Error (`Refused refusals)
  else
    match require_clang () with
    | Error m -> Error (`Toolchain m)
    | Ok cc -> (
        let runtime_dir = runtime_dir_of ~prelude_dir in
        if not (Sys.file_exists (Filename.concat runtime_dir "jq_value.h")) then
          Error
            (`Toolchain
               (Printf.sprintf "runtime sources not found at %s (set JACQUARD_RUNTIME)" runtime_dir))
        else
          let v_true =
            match Store.lookup_kind store "true" Resolve.KCon with
            | Some e -> e.Resolve.hash
            | None -> Hash.of_string "true"
          in
          let v_false =
            match Store.lookup_kind store "false" Resolve.KCon with
            | Some e -> e.Resolve.hash
            | None -> Hash.of_string "false"
          in
          let orderings =
            match
              ( Store.lookup_kind store "less" Resolve.KCon,
                Store.lookup_kind store "equal" Resolve.KCon,
                Store.lookup_kind store "greater" Resolve.KCon )
            with
            | Some l, Some e, Some g -> Some (l.Resolve.hash, e.Resolve.hash, g.Resolve.hash)
            | _ -> None
          in
          (* one unit per declaration: group members by owning decl *)
          let by_decl : (Hash.t, Compile.compiled_member list) Hashtbl.t = Hashtbl.create 32 in
          List.iter
            (fun (cm : Compile.compiled_member) ->
              match Hashtbl.find_opt d.member_binding cm.Compile.member with
              | Some (_, _, decl_hash) ->
                  Hashtbl.replace by_decl decl_hash
                    (cm :: (try Hashtbl.find by_decl decl_hash with Not_found -> []))
              | None -> ())
            prog.Emit.members;
          let units =
            Hashtbl.fold
              (fun decl_hash cms acc ->
                let hex = Emit.hex12 decl_hash in
                ("unit_" ^ hex, Emit.unit_source prog ~precise ~decl_hex:hex cms) :: acc)
              by_decl []
            |> List.sort compare
          in
          let main_c = Emit.main_source prog ~precise ~v_true ~v_false ~orderings ~intrinsics in
          let cflags =
            match Sys.getenv_opt "JACQUARD_NATIVE_CFLAGS" with Some f -> f | None -> ""
          in
          let cache_tag =
            let emitter_version = if precise then emitter_version else emitter_version ^ "-naive" in
            if cflags = "" then emitter_version
            else emitter_version ^ "-" ^ String.sub (Hash.to_hex (Hash.of_string cflags)) 0 8
          in
          let cache = Filename.concat ".jacquard-native" cache_tag in
          match link_program ~cc ~cache ~runtime_dir ~units ~main_c ~out with
          | Ok n -> Ok n
          | Error m -> Error (`Toolchain m))
