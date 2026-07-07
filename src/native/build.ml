(** The `jacquard build` driver (docs/native-plan.md, task 67): reachability over the store DAG,
    lowering, per-declaration C units cached by content, and the system-toolchain compile+link.
    clang or gcc (task 76; musttail needs clang or gcc 15+, older gcc rides the program stack at
    non-self tails); the cache directory carries the emitter version, so bumping [emitter_version]
    invalidates every unit. *)

open Jacquard

let emitter_version = "v1"

(* the default toolchain flags (task 84): -flto lets jq_dup/jq_drop and the
   intrinsics inline across units and libjqrt — measured 12-58% per program on the bench
   suite, byte-identical output, cold-build neutral. JACQUARD_NATIVE_CFLAGS
   appends afterwards, so an override (-fno-lto, sanitizers) wins. Both
   strings fold into the cache tag: changing them moves the directory. *)
let base_cflags = "-std=c11 -O2 -flto -Wall"
let base_ldflags = "-O2 -flto"

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
    ("text.trim", 1);
    ("text.split", 2);
    ("text.empty?", 1);
    ("text.from-int", 1);
    ("support", 1);
    ("pmf", 2);
    ("dist.sample-lw", 3);
    ("code.of-int", 1);
    ("code.to-int", 1);
    ("code.to-text", 1);
    ("code.form", 2);
    ("code.un-form", 1);
    ("code.eq?", 2);
    ("code.diff", 2);
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

let compile_program (store : Store.t) (d : discovery)
    (tops_src : (Kernel.expr * string list * (string * string) list) list) :
    outcome * (string * string) list list =
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
      (fun i (e, warnings, _) ->
        match
          Compile.lower_top ~store ~intrinsics:itbl ~builtin_names:d.builtin_names
            ~member_arity:d.member_arity ~index:i e
        with
        | body, lifted, deps, cons, ops ->
            List.iter enqueue deps;
            (body, lifted, warnings, cons, ops)
        | exception Compile.Refused r ->
            refusals := r :: !refusals;
            (Compile.Ret (Compile.AInt 0), [], warnings, [], []))
      tops_src
  in
  let manifests = List.map (fun (_, _, m) -> m) tops_src in
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
  (* monomorphization (task 69): call sites with statically-known arguments redirect to
     folded clones; runs before the con table so the table sees the final bodies *)
  let tops =
    if !refusals <> [] || Sys.getenv_opt "JACQUARD_SPEC" = Some "off" then tops
    else begin
      let implemented = Hashtbl.create 16 in
      Hashtbl.iter
        (fun h n -> if Hashtbl.mem itbl n then Hashtbl.replace implemented h n)
        d.builtin_names;
      let tops' =
        Spec.run ~members ~member_arity:d.member_arity ~builtin_names:implemented ~intrinsics:itbl
          ~tops:(List.map (fun (b, l, w, _, _) -> (b, l, w)) tops)
      in
      if Sys.getenv_opt "JACQUARD_SPEC_DEBUG" <> None then
        Printf.eprintf "spec: %d clones\n%!"
          (Hashtbl.fold
             (fun _ (cm : Compile.compiled_member) acc ->
               if Filename.check_suffix cm.Compile.mname "@spec" then acc + 1 else acc)
             members 0);
      List.map2 (fun (b, l, w) (_, _, _, cs, ops) -> (b, l, w, cs, ops)) tops' tops
    end
  in
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
  List.iter (fun (_, _, _, cs, _) -> List.iter note_con cs) tops;
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
    [ "less"; "equal"; "greater"; "nil"; "cons"; "mk-pair"; "some"; "none" ];
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
  (* effect operations: dense link-time ordinals, sorted by hash for determinism *)
  let ops : (Hash.t, Emit.opref) Hashtbl.t = Hashtbl.create 8 in
  let all_ops = Hashtbl.create 8 in
  List.iter
    (fun (cm : Compile.compiled_member) ->
      List.iter (fun h -> Hashtbl.replace all_ops h ()) cm.Compile.ops_used)
    member_list;
  List.iter (fun (_, _, _, _, os) -> List.iter (fun h -> Hashtbl.replace all_ops h ()) os) tops;
  let op_list =
    Hashtbl.fold (fun h () acc -> h :: acc) all_ops []
    |> List.sort (fun a b -> compare (Hash.to_hex a) (Hash.to_hex b))
  in
  List.iteri
    (fun i h ->
      match Store.locate store h with
      | Ok
          {
            Store.decl = { Kernel.it = Kernel.DefEffect { ename; ops = specs; _ }; _ };
            role = Store.Operation oi;
            _;
          } ->
          let oname =
            match List.nth_opt specs oi with Some { Kernel.op_name; _ } -> op_name | None -> "?"
          in
          Hashtbl.replace ops h { Emit.ohash = h; oeffect = ename; oname; oord = i }
      | _ -> ())
    op_list;
  (* frame-style classification (task 71): a fn may suspend when its body performs,
     handles, applies an unknown callee, or calls a member that may — the fixed point
     over known-call edges. Top-level expression bodies and const initializers stay
     direct: any capturing handler they involve lives INSIDE the expression, so a
     capture always resolves within it and never unwinds past its C activation. *)
  let expr_facts (e : Compile.expr) : bool * (Hash.t * int) list =
    let direct = ref false in
    let calls = ref [] in
    let bound = function
      | Compile.BPerform _ | Compile.BHandle _ | Compile.BCallUnknown _ -> direct := true
      | Compile.BCallKnown (code, _) -> calls := code :: !calls
      | _ -> ()
    in
    let rec go = function
      | Compile.Ret _ | Compile.TailSelf _ -> ()
      | Compile.LetReuse (_, _, _, body) | Compile.Drop (_, body) -> go body
      | Compile.Let (_, b, body) ->
          bound b;
          go body
      | Compile.Match (_, cls) -> List.iter (fun (_, b) -> go b) cls
      | Compile.TailKnown (code, _, _) -> calls := code :: !calls
      | Compile.TailUnknown _ -> direct := true
    in
    go e;
    (!direct, !calls)
  in
  let framed_fns : (Hash.t * int, unit) Hashtbl.t = Hashtbl.create 64 in
  let framed_members : (Hash.t, unit) Hashtbl.t = Hashtbl.create 64 in
  let fn_facts =
    List.concat_map
      (fun (cm : Compile.compiled_member) ->
        let of_fn ~entry (f : Compile.fn) =
          let direct, calls = expr_facts f.Compile.body in
          (f.Compile.fname, (if entry then Some cm.Compile.member else None), direct, calls)
        in
        (match cm.Compile.main_fn with Some f -> [ of_fn ~entry:true f ] | None -> [])
        @ List.map (of_fn ~entry:false) cm.Compile.lifted)
      member_list
    @ List.concat_map
        (fun (_, lifted, _, _, _) ->
          List.map
            (fun (f : Compile.fn) ->
              let direct, calls = expr_facts f.Compile.body in
              (f.Compile.fname, None, direct, calls))
            lifted)
        tops
  in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun (fname, member_opt, direct, calls) ->
        if not (Hashtbl.mem framed_fns fname) then
          if direct || List.exists (Hashtbl.mem framed_fns) calls then begin
            Hashtbl.replace framed_fns fname ();
            (match member_opt with Some m -> Hashtbl.replace framed_members m () | None -> ());
            changed := true
          end)
      fn_facts
  done;
  let prog =
    {
      Emit.members = member_list;
      member_arity = d.member_arity;
      builtin_names =
        (let t = Hashtbl.create 16 in
         Hashtbl.iter (fun h n -> if Hashtbl.mem itbl n then Hashtbl.replace t h n) d.builtin_names;
         t);
      cons;
      ops;
      tops = List.map (fun (b, l, w, _, _) -> (b, l, w)) tops;
      init_order = List.rev !order;
      framed_fns;
      framed_members;
    }
  in
  ({ prog; refusals = List.rev !refusals }, manifests)

(* ------------------------------------------------------------------ *)
(* Toolchain                                                           *)
(* ------------------------------------------------------------------ *)

let run_cmd_quiet (cmd : string) : int = Sys.command cmd
let quote = Filename.quote

let require_toolchain () : (string, string) result =
  (* task 76: clang or gcc. Guaranteed tail calls come from musttail (clang
     anywhere, gcc from 15); older gcc compiles the same C with plain calls
     at non-self tail sites, bounded by the program stack like non-tail
     recursion — jq_value.h documents the boundary. *)
  let cc = match Sys.getenv_opt "CC" with Some c -> c | None -> "cc" in
  (* identify by the preprocessor's own macros, not the version banner:
     Ubuntu's `cc` says "cc (Ubuntu ...)" without naming gcc (review find) *)
  let ic =
    Unix.open_process_in
      (quote cc ^ " -dM -E - < /dev/null 2>/dev/null | grep -c -E '__clang__|__GNUC__'")
  in
  let hits = try input_line ic with End_of_file -> "0" in
  ignore (Unix.close_process_in ic);
  if hits <> "0" then Ok cc
  else
    Error
      (Printf.sprintf "jacquard build requires clang or gcc; CC resolves to `%s` (%s)" cc
         (let ic = Unix.open_process_in (quote cc ^ " --version 2>/dev/null") in
          let first = try input_line ic with End_of_file -> "" in
          ignore (Unix.close_process_in ic);
          if first = "" then "not found" else first))

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
        Printf.sprintf "%s %s %s -I %s -c %s -o %s" (quote cc) base_cflags extra (quote runtime_dir)
          (quote c_path) (quote o_path)
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
        Printf.sprintf "%s %s %s %s -o %s -lm -lpthread" (quote cc) base_ldflags extra
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
let build ~(store : Store.t) ~(tops : (Kernel.expr * string list * (string * string) list) list)
    ~prelude_dir ~out : (int, [ `Refused of Compile.refusal list | `Toolchain of string ]) result =
  let d = discover store in
  let { prog; refusals }, manifests = compile_program store d tops in
  (* Perceus (task 68): precise ownership unless the differential lever turns it off.
     Frame-style fns (task 71) stay on the naive discipline: a suspension abandons its
     locals to the frame, which the move/Drop bookkeeping does not model — the emitter
     handles their counts uniformly (dup on use, drop at exits). *)
  let precise = Sys.getenv_opt "JACQUARD_PERCEUS" <> Some "off" in
  (* framed fns get the precise walk too (task 82), with reuse tokens off:
     a detached shell held across a suspension has no owner in the frame *)
  let framed (f : Compile.fn) = Hashtbl.mem prog.Emit.framed_fns f.Compile.fname in
  let pfn (f : Compile.fn) = Perceus.fn ~reuse:(not (framed f)) f in
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
                Compile.main_fn = Option.map pfn cm.Compile.main_fn;
                const_body =
                  Option.map
                    (fun b ->
                      Perceus.reset_tokens ();
                      Perceus.walk Perceus.SSet.empty b)
                    cm.Compile.const_body;
                lifted = List.map pfn cm.Compile.lifted;
              })
            prog.Emit.members;
        tops =
          List.map
            (fun (body, lifted, warnings) ->
              Perceus.reset_tokens ();
              (Perceus.walk Perceus.SSet.empty body, List.map pfn lifted, warnings))
            prog.Emit.tops;
      }
  in
  if refusals <> [] then Error (`Refused refusals)
  else
    match require_toolchain () with
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
          let listcons =
            match
              ( Store.lookup_kind store "nil" Resolve.KCon,
                Store.lookup_kind store "cons" Resolve.KCon )
            with
            | Some n, Some c -> Some (n.Resolve.hash, c.Resolve.hash)
            | _ -> None
          in
          let pair =
            match Store.lookup_kind store "mk-pair" Resolve.KCon with
            | Some p -> Some p.Resolve.hash
            | None -> None
          in
          let option_cons =
            match
              ( Store.lookup_kind store "some" Resolve.KCon,
                Store.lookup_kind store "none" Resolve.KCon )
            with
            | Some so, Some no -> Some (so.Resolve.hash, no.Resolve.hash)
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
              | None ->
                  (* a specialization: its content-hash key IS its unit, so the spec cache
                     persists across builds like any declaration (pillar 3) *)
                  Hashtbl.replace by_decl cm.Compile.member [ cm ])
            prog.Emit.members;
          let units =
            Hashtbl.fold
              (fun decl_hash cms acc ->
                let hex = Emit.hex12 decl_hash in
                ("unit_" ^ hex, Emit.unit_source prog ~precise ~decl_hex:hex cms) :: acc)
              by_decl []
            |> List.sort compare
          in
          let main_c =
            Emit.main_source prog ~precise ~v_true ~v_false ~orderings ~listcons ~pair ~option_cons
              ~intrinsics ~manifests
          in
          let cflags =
            match Sys.getenv_opt "JACQUARD_NATIVE_CFLAGS" with Some f -> f | None -> ""
          in
          let cache_tag =
            let emitter_version = if precise then emitter_version else emitter_version ^ "-naive" in
            let emitter_version =
              if Sys.getenv_opt "JACQUARD_SPEC" = Some "off" then emitter_version ^ "-nospec"
              else emitter_version
            in
            (* the runtime header defines jq_rt's layout, which every cached .o bakes in:
               a header change must move the WHOLE cache directory, or byte-identical
               units keep stale field offsets and the link mixes layouts (task 71 review
               found the mixed binary reading apply_n at the old offset) *)
            let emitter_version =
              emitter_version ^ "-h"
              ^ String.sub
                  (Hash.to_hex
                     (Hash.of_string (read_file (Filename.concat runtime_dir "jq_value.h"))))
                  0 8
            in
            (* the toolchain too (task 76 sign-off find): .o files are
               compiler-specific, and compile_c skips existing objects, so a
               clang cache must never serve a gcc link *)
            let emitter_version =
              let ic = Unix.open_process_in (quote cc ^ " --version 2>/dev/null") in
              let banner = try input_line ic with End_of_file -> "" in
              ignore (Unix.close_process_in ic);
              emitter_version ^ "-t"
              ^ String.sub (Hash.to_hex (Hash.of_string (cc ^ "|" ^ banner))) 0 8
            in
            let flags = base_cflags ^ "|" ^ base_ldflags ^ "|" ^ cflags in
            emitter_version ^ "-f" ^ String.sub (Hash.to_hex (Hash.of_string flags)) 0 8
          in
          let cache = Filename.concat ".jacquard-native" cache_tag in
          match link_program ~cc ~cache ~runtime_dir ~units ~main_c ~out with
          | Ok n -> Ok n
          | Error m -> Error (`Toolchain m))
