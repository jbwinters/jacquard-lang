(** NIR -> C emission (docs/native-plan.md, task 67).

    One C unit per store DECLARATION (all members of a defterm group together); a generated main
    unit carries constructor infos, once-initialized member cells, and the per-expression driver
    loop. Naming is content-addressed and stable: functions [j_<hex12>], value cells [g_<hex12>],
    constructor infos [jq_ci_<hex12>] — units extern-declare what they use, so there is no shared
    generated header and per-unit caching is exact.

    Calling convention: every compiled function has the uniform signature
    [jq_value f(jq_rt*, jq_value clo, jq_value a0..a7)] because clang's musttail requires the caller
    and callee prototypes to match; unused argument slots carry JQ_UNIT and arity is capped at 8
    (E1101 above). Members ignore [clo]; lifted lambdas read their environment from it.

    Reference counting is the naive placeholder Perceus replaces in task 68, kept correct by two
    uniform rules: every use of an atom dups, and every exit dups the result then drops all owned
    locals. The insertion points live in this module only. *)

open Jacquard
open Compile

let max_arity = 8

(* ------------------------------------------------------------------ *)
(* Names                                                               *)
(* ------------------------------------------------------------------ *)

let hex12 (h : Hash.t) = String.sub (Hash.to_hex h) 0 12

let fn_name (h, ordinal) =
  if ordinal = 0 then "j_" ^ hex12 h else Printf.sprintf "j_%s_%d" (hex12 h) ordinal

let cell_name h = "g_" ^ hex12 h
let init_name h = "init_" ^ hex12 h
let ci_name h = "jq_ci_" ^ hex12 h
let oi_name h = "jq_oi_" ^ hex12 h

(* C-safe identifier fragment for builtin and effect names ('?' marks predicates) *)
let mangle s =
  String.concat ""
    (List.map
       (fun c -> match c with '.' | '-' -> "_" | '?' -> "_q" | c -> String.make 1 c)
       (List.init (String.length s) (String.get s)))

(* ------------------------------------------------------------------ *)
(* Emission buffer                                                     *)
(* ------------------------------------------------------------------ *)

type buf = { b : Buffer.t; mutable indent : int }

let line buf fmt =
  Printf.ksprintf
    (fun s ->
      Buffer.add_string buf.b (String.make (2 * buf.indent) ' ');
      Buffer.add_string buf.b s;
      Buffer.add_char buf.b '\n')
    fmt

(* ------------------------------------------------------------------ *)
(* Program-level info the emitter needs                                *)
(* ------------------------------------------------------------------ *)

type conref = { chash : Hash.t; cname : string; carity : int; ctype_id : int; cordinal : int }

type opref = {
  ohash : Hash.t;
  oeffect : string;
  oname : string;
  oord : int;  (** dense link-time ordinal: the perform/grant index *)
}

type program = {
  members : compiled_member list;  (** every reachable member, lowered *)
  member_arity : (Hash.t, int) Hashtbl.t;
  builtin_names : (Hash.t, string) Hashtbl.t;  (** implemented intrinsics only, by member *)
  cons : (Hash.t, conref) Hashtbl.t;  (** every constructor the program touches *)
  ops : (Hash.t, opref) Hashtbl.t;  (** every effect operation the program touches *)
  tops : (expr * fn list * string list) list;
      (** per top-level expression: body, lifted lambdas, checker warnings to replay *)
  init_order : Hash.t list;  (** const members in dependency order *)
}

(* C string literal for arbitrary bytes *)
let c_string (s : string) =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | c when Char.code c < 0x20 || Char.code c >= 0x7f ->
          (* octal escapes are 1-3 digits and never mis-munch a following hex char *)
          Buffer.add_string b (Printf.sprintf "\\%03o" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* C double literal that reparses to the identical double *)
let c_double (r : float) =
  if Float.is_nan r then "(0.0/0.0)"
  else if r = Float.infinity then "(1.0/0.0)"
  else if r = Float.neg_infinity then "(-1.0/0.0)"
  else Printf.sprintf "%h" r (* hex float: exact, no rounding ambiguity *)

(* ------------------------------------------------------------------ *)
(* Per-unit emission state                                             *)
(* ------------------------------------------------------------------ *)

type unit_state = {
  prog : program;
  precise : bool;
      (** Perceus ran (task 68): moves and Drop nodes own every count; the emitter adds no
          exit-point drops of its own. False = the naive skeleton discipline. *)
  ub : buf;  (** unit body: functions *)
  decls : buf;  (** extern declarations and unit-local statics, emitted first *)
  mutable declared : SSet.t;  (** dedup for externs/statics *)
  mutable statics : int;  (** unit-local static counter (texts, reals, values) *)
}

let declare st key emit =
  if not (SSet.mem key st.declared) then begin
    st.declared <- SSet.add key st.declared;
    emit ()
  end

let static_name st prefix =
  st.statics <- st.statics + 1;
  Printf.sprintf "%s_%d" prefix st.statics

(* Every unit-local static block uses the layout-compatible sized-payload struct (a flexible
   array member cannot be statically initialized). *)
let emit_static_block st name ~tag ~flags ~n ~payload_words ~payload =
  line st.decls
    "static struct { uint32_t rc; uint8_t tag; uint8_t flags; uint16_t n; uint64_t p[%d]; }"
    (max 1 payload_words);
  line st.decls "  %s = { UINT32_MAX, %s, %d, %d, { %s } };" name tag flags n
    (if payload = [] then "0" else String.concat ", " payload)

let declare_con_info st (h : Hash.t) =
  declare st ("ci:" ^ hex12 h) (fun () -> line st.decls "extern const jq_con_info %s;" (ci_name h))

(* The static value for a constructor used as a value: arity 0 is the CON itself. *)
let con_value_static st (h : Hash.t) =
  let cr = Hashtbl.find st.prog.cons h in
  declare_con_info st h;
  let key = "cv:" ^ hex12 h in
  let name = "cv_" ^ hex12 h in
  declare st key (fun () ->
      if cr.carity = 0 then
        emit_static_block st name ~tag:"JQ_CON" ~flags:0 ~n:1 ~payload_words:1
          ~payload:[ Printf.sprintf "(uint64_t)&%s" (ci_name h) ]
      else
        emit_static_block st name ~tag:"JQ_CONSTRUCTOR" ~flags:0 ~n:1 ~payload_words:1
          ~payload:[ Printf.sprintf "(uint64_t)&%s" (ci_name h) ]);
  Printf.sprintf "((jq_value)&%s)" name

let declare_op_info st (h : Hash.t) =
  declare st ("oi:" ^ hex12 h) (fun () -> line st.decls "extern const jq_op_info %s;" (oi_name h))

(* A first-class effect operation: a static OP block over the shared info. *)
let op_value_static st (h : Hash.t) =
  declare_op_info st h;
  let name = "ov_" ^ hex12 h in
  declare st
    ("ov:" ^ hex12 h)
    (fun () ->
      emit_static_block st name ~tag:"JQ_OP" ~flags:0 ~n:1 ~payload_words:1
        ~payload:[ Printf.sprintf "(uint64_t)&%s" (oi_name h) ]);
  Printf.sprintf "((jq_value)&%s)" name

(* A member used as a value: function members get a unit-local static closure over their
   uniform-signature function; intrinsic builtins a static BUILTIN block; const members the
   extern init-once cell. *)
let global_value st (h : Hash.t) =
  match Hashtbl.find_opt st.prog.builtin_names h with
  | Some bname ->
      let key = "bv:" ^ hex12 h in
      let name = "bv_" ^ hex12 h in
      declare st ("bi:" ^ bname) (fun () ->
          line st.decls "extern const jq_builtin_info jq_bi_%s;" (mangle bname));
      declare st key (fun () ->
          emit_static_block st name ~tag:"JQ_BUILTIN" ~flags:0 ~n:1 ~payload_words:1
            ~payload:[ Printf.sprintf "(uint64_t)&jq_bi_%s" (mangle bname) ]);
      Printf.sprintf "((jq_value)&%s)" name
  | None -> (
      match Hashtbl.find_opt st.prog.member_arity h with
      | Some arity ->
          let fname = fn_name (h, 0) in
          declare st ("fn:" ^ fname) (fun () ->
              line st.decls "extern jq_value %s(JQ_PARAMS);" fname);
          let key = "fv:" ^ hex12 h in
          let name = "fv_" ^ hex12 h in
          declare st key (fun () ->
              emit_static_block st name ~tag:"JQ_CLOSURE" ~flags:0 ~n:2 ~payload_words:2
                ~payload:[ Printf.sprintf "(uint64_t)&%s" fname; Printf.sprintf "%d" arity ]);
          Printf.sprintf "((jq_value)&%s)" name
      | None ->
          let cell = cell_name h in
          declare st ("cell:" ^ cell) (fun () -> line st.decls "extern jq_value %s;" cell);
          cell)

(* literal statics dedup by content: the name is the content hash *)
let text_static st (s : string) =
  let name = "ts_" ^ String.sub (Hash.to_hex (Hash.of_string s)) 0 12 in
  declare st ("ts:" ^ name) (fun () ->
      let len = String.length s in
      line st.decls
        "static const struct { uint32_t rc; uint8_t tag; uint8_t flags; uint16_t n; uint64_t len; \
         uint8_t bytes[%d]; }"
        (max 1 len);
      line st.decls "  %s = { UINT32_MAX, JQ_TEXT, 0, 0, %d, %s };" name len
        (if len = 0 then "{ 0 }" else c_string s));
  Printf.sprintf "((jq_value)&%s)" name

let real_static st (r : float) =
  let name = Printf.sprintf "rs_%Lx" (Int64.bits_of_float r) in
  declare st ("rs:" ^ name) (fun () ->
      line st.decls
        "static struct { uint32_t rc; uint8_t tag; uint8_t flags; uint16_t n; double d; }";
      line st.decls "  %s = { UINT32_MAX, JQ_REAL, 0, 1, %s };" name (c_double r));
  Printf.sprintf "((jq_value)&%s)" name

(* ------------------------------------------------------------------ *)
(* Atoms                                                               *)
(* ------------------------------------------------------------------ *)

(* The C expression for an atom (no ownership transfer). *)
let rec atom_c st (a : atom) : string =
  match a with
  | AMove inner -> atom_c st inner
  | AVar x -> x
  | AEnv i -> Printf.sprintf "jq_closure_env(clo)[%d]" i
  | AInt i -> Printf.sprintf "jq_int(%dLL)" i
  | AReal r -> real_static st r
  | AText s -> text_static st s
  | AGlobal h -> global_value st h
  | ACon h -> con_value_static st h
  | AOp h -> op_value_static st h
  | AResume () -> failwith "internal: a resume marker reached the emitter"

(* A use: the receiver takes ownership, so dup (no-op for ints and statics). *)
let use st buf (a : atom) : string =
  match a with
  | AInt _ -> atom_c st a
  | AMove inner -> atom_c st inner (* ownership transfers: Perceus proved the last use *)
  | _ ->
      let e = atom_c st a in
      line buf "jq_dup(%s);" e;
      e

(* ------------------------------------------------------------------ *)
(* Patterns                                                            *)
(* ------------------------------------------------------------------ *)

(* Compile a pattern over the C path expression [subject] into a test (C boolean expression,
   pieces AND-ed) and bindings (emitted only when the whole clause matched). Field paths read
   through the block accessors without owning; binds dup. *)
let rec pat_test st (subject : string) (p : npat) : string list =
  match p with
  | NPWild | NPVar _ -> []
  | NPAs (_, inner) -> pat_test st subject inner
  | NPLit (Kernel.LInt i) ->
      [ Printf.sprintf "(jq_is_int(%s) && jq_int_val(%s) == %dLL)" subject subject i ]
  | NPLit (Kernel.LReal r) ->
      (* interpreter lit_matches: Float.compare (nan matches nan) or both zeros *)
      [
        Printf.sprintf
          "(jq_is_ptr(%s) && jq_block_of(%s)->tag == JQ_REAL && jq_real_lit_match(jq_real_val(%s), \
           %s))"
          subject subject subject (c_double r);
      ]
  | NPLit (Kernel.LText s) ->
      let lit = text_static st s in
      [
        Printf.sprintf "(jq_is_ptr(%s) && jq_block_of(%s)->tag == JQ_TEXT && jq_text_eq(%s, %s))"
          subject subject subject lit;
      ]
  | NPCon (h, ps) ->
      declare_con_info st h;
      let head =
        Printf.sprintf
          "(jq_is_ptr(%s) && jq_block_of(%s)->tag == JQ_CON && jq_con_info_of(%s) == &%s)" subject
          subject subject (ci_name h)
      in
      head
      :: List.concat
           (List.mapi
              (fun i p -> pat_test st (Printf.sprintf "jq_con_fields(%s)[%d]" subject i) p)
              ps)
  | NPTuple ps ->
      let head =
        Printf.sprintf
          "(jq_is_ptr(%s) && jq_block_of(%s)->tag == JQ_TUPLE && jq_tuple_arity(%s) == %d)" subject
          subject subject (List.length ps)
      in
      head
      :: List.concat
           (List.mapi (fun i p -> pat_test st (Printf.sprintf "jq_fields(%s)[%d]" subject i) p) ps)

let rec pat_bind st buf (subject : string) (p : npat) : string list =
  match p with
  | NPWild | NPLit _ -> []
  | NPVar x ->
      line buf "jq_value %s = %s;" x subject;
      line buf "jq_dup(%s);" x;
      [ x ]
  | NPAs (x, inner) ->
      line buf "jq_value %s = %s;" x subject;
      line buf "jq_dup(%s);" x;
      x :: pat_bind st buf subject inner
  | NPCon (_, ps) ->
      List.concat
        (List.mapi
           (fun i p -> pat_bind st buf (Printf.sprintf "jq_con_fields(%s)[%d]" subject i) p)
           ps)
  | NPTuple ps ->
      List.concat
        (List.mapi (fun i p -> pat_bind st buf (Printf.sprintf "jq_fields(%s)[%d]" subject i) p) ps)

(* ------------------------------------------------------------------ *)
(* Expressions                                                         *)
(* ------------------------------------------------------------------ *)

type exit_kind =
  | EReturn  (** function body: dup result, drop lives, return *)
  | EAssign of string * string  (** top-level: assign to a var and goto the label *)

(* [emit_expr st buf lives exit e]: [lives] is every owned local in scope, innermost last;
   [tokens] are live reuse shells — every exit frees the leftovers (branch-safe). *)
let rec emit_expr ?(tokens = []) st buf (lives : string list) (exit : exit_kind) (e : expr) : unit =
  let exit_drops () =
    if not st.precise then List.iter (fun l -> line buf "jq_drop(%s);" l) lives;
    List.iter (fun t -> line buf "if (%s) free(%s);" t t) tokens
  in
  match e with
  | LetReuse (tok, x, _, body) ->
      line buf "jq_block *%s = jq_reuse_take(%s);" tok x;
      emit_expr ~tokens:(tok :: tokens) st buf lives exit body
  | Drop (xs, body) ->
      List.iter (fun x -> line buf "jq_drop(%s);" x) xs;
      emit_expr ~tokens st buf lives exit body
  | Ret a -> (
      (* materialize BEFORE the drops: the use expression may read through a local the
         drops free (naive mode returning an env slot re-read clo after jq_drop(clo)) *)
      let v = use st buf a in
      line buf "jq_value _ret = %s;" v;
      match exit with
      | EReturn ->
          exit_drops ();
          line buf "return _ret;"
      | EAssign (var, label) ->
          exit_drops ();
          line buf "%s = _ret;" var;
          line buf "goto %s;" label)
  | Let (x, b, body) ->
      emit_bound st buf lives x b;
      emit_expr ~tokens st buf (x :: lives) exit body
  | Match (a, clauses) ->
      let subject = atom_c st a in
      let rec arms = function
        | [] -> line buf "jq_match_fail(rt, %s);" subject
        | (p, body) :: rest ->
            let tests = pat_test st subject p in
            let cond = if tests = [] then "1" else String.concat " && " tests in
            line buf "if (%s) {" cond;
            buf.indent <- buf.indent + 1;
            let binds = pat_bind st buf subject p in
            emit_expr ~tokens st buf (List.rev_append binds lives) exit body;
            buf.indent <- buf.indent - 1;
            line buf "} else {";
            buf.indent <- buf.indent + 1;
            arms rest;
            buf.indent <- buf.indent - 1;
            line buf "}"
      in
      arms clauses
  | TailSelf (args, post) -> (
      let temps =
        List.mapi
          (fun i a ->
            let t = Printf.sprintf "_n%d" i in
            let v = use st buf a in
            line buf "jq_value %s = %s;" t v;
            t)
          args
      in
      if not st.precise then List.iter (fun l -> line buf "jq_drop(%s);" l) lives;
      List.iter (fun l -> line buf "jq_drop(%s);" l) post;
      List.iter (fun t -> line buf "if (%s) free(%s);" t t) tokens;
      List.iteri (fun i t -> line buf "a%d = %s;" i t) temps;
      match exit with
      | EReturn -> line buf "goto entry;"
      | EAssign _ ->
          (* top-level expressions have no self *)
          line buf "goto entry;")
  | TailKnown (h, args, post) ->
      let fname = fn_name (h, 0) in
      declare st ("fn:" ^ fname) (fun () -> line st.decls "extern jq_value %s(JQ_PARAMS);" fname);
      emit_tail_call st buf lives exit ~post ~tokens
        (fun padded -> Printf.sprintf "%s(rt, JQ_UNIT, %s)" fname padded)
        args
  | TailUnknown (f, args, post) ->
      let fv = use st buf f in
      let t = "_f" in
      line buf "jq_value %s = %s;" t fv;
      line buf "rt->apply_n = %d;" (List.length args);
      emit_tail_call st buf (t :: lives) exit ~consumes:[ t ] ~post ~tokens
        (fun padded -> Printf.sprintf "jq_apply(rt, %s, %s)" t padded)
        args

and emit_tail_call st buf lives exit ?(consumes = []) ?(post = []) ?(tokens = []) mk
    (args : atom list) : unit =
  if List.length args > max_arity then failwith "arity cap not enforced upstream";
  let temps =
    List.mapi
      (fun i a ->
        let t = Printf.sprintf "_t%d" i in
        let v = use st buf a in
        line buf "jq_value %s = %s;" t v;
        t)
      args
  in
  (* the callee consumes temps (and [consumes]); in naive mode everything else live drops
     here, BEFORE the musttail. Precise mode: the pass placed a Drop node ahead already. *)
  if not st.precise then
    List.iter (fun l -> if not (List.mem l consumes) then line buf "jq_drop(%s);" l) lives;
  List.iter (fun l -> line buf "jq_drop(%s);" l) post;
  List.iter (fun t -> line buf "if (%s) free(%s);" t t) tokens;
  let padded =
    temps @ List.init (max_arity - List.length temps) (fun _ -> "JQ_UNIT") |> String.concat ", "
  in
  match exit with
  | EReturn -> line buf "JQ_MUSTTAIL return %s;" (mk padded)
  | EAssign (var, label) ->
      line buf "%s = %s;" var (mk padded);
      line buf "goto %s;" label

and emit_bound st buf lives (x : string) (b : bound) : unit =
  ignore lives;
  match b with
  | BAtom a ->
      let v = use st buf a in
      line buf "jq_value %s = %s;" x v
  | BCallKnown (h, args) ->
      let fname = fn_name (h, 0) in
      declare st ("fn:" ^ fname) (fun () -> line st.decls "extern jq_value %s(JQ_PARAMS);" fname);
      let vs = List.map (fun a -> use st buf a) args in
      let padded =
        vs @ List.init (max_arity - List.length vs) (fun _ -> "JQ_UNIT") |> String.concat ", "
      in
      line buf "jq_value %s = %s(rt, JQ_UNIT, %s);" x fname padded
  | BCallUnknown (f, args) ->
      let fv = use st buf f in
      let vs = List.map (fun a -> use st buf a) args in
      let padded =
        vs @ List.init (max_arity - List.length vs) (fun _ -> "JQ_UNIT") |> String.concat ", "
      in
      line buf "rt->apply_n = %d;" (List.length args);
      line buf "jq_value %s = jq_apply(rt, %s, %s);" x fv padded
  | BAllocCon (h, args) ->
      declare_con_info st h;
      let vs = List.map (fun a -> use st buf a) args in
      if vs = [] then line buf "jq_value %s = jq_con(&%s, NULL);" x (ci_name h)
      else
        line buf "jq_value %s = jq_con(&%s, (jq_value[]){ %s });" x (ci_name h)
          (String.concat ", " vs)
  | BAllocConReuse (h, args, tok) ->
      declare_con_info st h;
      let vs = List.map (fun a -> use st buf a) args in
      line buf "jq_value %s = jq_con_reuse(%s, &%s, (jq_value[]){ %s });" x tok (ci_name h)
        (String.concat ", " vs);
      line buf "%s = NULL;" tok
  | BAllocTuple args ->
      let vs = List.map (fun a -> use st buf a) args in
      if vs = [] then line buf "jq_value %s = JQ_UNIT;" x
      else
        line buf "jq_value %s = jq_tuple(%d, (jq_value[]){ %s });" x (List.length vs)
          (String.concat ", " vs)
  | BAllocClosure { code; captured; self_slot; arity } -> (
      let fname = fn_name code in
      declare st ("fn:" ^ fname) (fun () -> line st.decls "extern jq_value %s(JQ_PARAMS);" fname);
      let vs =
        List.mapi
          (fun i a ->
            if self_slot = Some i then "JQ_UNIT" (* patched below, stored without dup *)
            else use st buf a)
          captured
      in
      let env =
        if vs = [] then "NULL" else Printf.sprintf "(jq_value[]){ %s }" (String.concat ", " vs)
      in
      line buf "jq_value %s = jq_closure((void *)&%s, %d, %d, %s, %s);" x fname arity
        (List.length captured) env
        (match self_slot with Some i -> string_of_int i | None -> "UINT16_MAX");
      match self_slot with Some i -> line buf "jq_closure_env(%s)[%d] = %s;" x i x | None -> ())
  | BIntrinsic (name, args) ->
      let vs = List.map (fun a -> use st buf a) args in
      let cname = mangle name in
      if vs = [] then line buf "jq_value %s = jq_i_%s(rt, NULL);" x cname
      else line buf "jq_value %s = jq_i_%s(rt, (jq_value[]){ %s });" x cname (String.concat ", " vs)
  | BPerform (h, args) ->
      let oref = Hashtbl.find st.prog.ops h in
      let vs = List.map (fun a -> use st buf a) args in
      if vs = [] then line buf "jq_value %s = jq_perform(rt, %d, 0, NULL);" x oref.oord
      else
        line buf "jq_value %s = jq_perform(rt, %d, %d, (jq_value[]){ %s });" x oref.oord
          (List.length vs) (String.concat ", " vs)
  | BHandle (entries, thunk) ->
      (* push owns the clause refs; the apply consumes the thunk; pop releases the clauses *)
      let evs =
        List.map
          (fun (oh, a) ->
            let oref = Hashtbl.find st.prog.ops oh in
            Printf.sprintf "{ %d, %s }" oref.oord (use st buf a))
          entries
      in
      line buf "jq_handler_entry _he_%s[] = { %s };" x (String.concat ", " evs);
      line buf "jq_handle_push(rt, %d, _he_%s);" (List.length entries) x;
      let tv = use st buf thunk in
      line buf "rt->apply_n = 0;";
      line buf
        "jq_value %s = jq_apply(rt, %s, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, \
         JQ_UNIT, JQ_UNIT);"
        x tv;
      line buf "jq_handle_pop(rt, %d);" (List.length entries)

(* ------------------------------------------------------------------ *)
(* Functions                                                           *)
(* ------------------------------------------------------------------ *)

let emit_fn st (f : fn) : unit =
  let buf = st.ub in
  line buf "";
  line buf "jq_value %s(JQ_PARAMS) {" (fn_name f.fname);
  buf.indent <- buf.indent + 1;
  line buf "(void)rt; (void)clo;";
  (* silence unused padding args *)
  for i = f.n_params to max_arity - 1 do
    line buf "(void)a%d;" i
  done;
  if f.self_entry then line buf "entry:;";
  (* prologue: bind parameter patterns; failure reproduces the interpreter's Match_failure *)
  let lives = ref [ "clo" ] in
  List.iteri
    (fun i p ->
      let subject = Printf.sprintf "a%d" i in
      lives := subject :: !lives;
      match p with
      | NPVar x ->
          (* the param IS the local: transfer ownership, no dup *)
          line buf "jq_value %s = %s;" x subject;
          lives := x :: List.filter (fun l -> l <> subject) !lives
      | NPWild -> ()
      | _ ->
          let tests = pat_test st subject p in
          let cond = if tests = [] then "1" else String.concat " && " tests in
          line buf "if (!(%s)) jq_match_fail(rt, %s);" cond subject;
          let binds = pat_bind st buf subject p in
          lives := List.rev_append binds !lives)
    f.params;
  emit_expr st buf !lives EReturn f.body;
  buf.indent <- buf.indent - 1;
  line buf "}"

(* ------------------------------------------------------------------ *)
(* Unit and main-source generation                                     *)
(* ------------------------------------------------------------------ *)

let new_state ?(precise = false) prog =
  {
    prog;
    precise;
    ub = { b = Buffer.create 4096; indent = 0 };
    decls = { b = Buffer.create 1024; indent = 0 };
    declared = SSet.empty;
    statics = 0;
  }

let assemble st ~banner =
  let out = Buffer.create (Buffer.length st.decls.b + Buffer.length st.ub.b + 256) in
  Buffer.add_string out banner;
  Buffer.add_string out
    "#include \"jq_value.h\"\n\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n\n";
  Buffer.add_buffer out st.decls.b;
  Buffer.add_buffer out st.ub.b;
  Buffer.contents out

(** One C unit per store declaration: the functions of every member in it (const bodies live in the
    main unit's init functions; their lifted lambdas still live here). *)
let unit_source (prog : program) ~precise ~(decl_hex : string) (members : compiled_member list) :
    string =
  let st = new_state ~precise prog in
  List.iter
    (fun (m : compiled_member) ->
      line st.ub "";
      line st.ub "/* %s */" m.mname;
      Option.iter (emit_fn st) m.main_fn;
      List.iter (emit_fn st) m.lifted)
    members;
  assemble st
    ~banner:
      (Printf.sprintf "/* generated by jacquard build (task 67) — declaration %s; do not edit */\n"
         decl_hex)

(** The main unit: constructor infos, builtin infos, init-once cells, and the per-expression driver
    with the interpreter's output and exit-code contract. *)
let main_source (prog : program) ~precise ~(v_true : Hash.t) ~(v_false : Hash.t)
    ~(orderings : (Hash.t * Hash.t * Hash.t) option) ~(listcons : (Hash.t * Hash.t) option)
    ~(intrinsics : (string * int) list) ~(manifests : (string * string) list list) : string =
  let st = new_state ~precise prog in
  (* constructor infos: the shared identities every unit externs *)
  let cons = Hashtbl.fold (fun _ cr acc -> cr :: acc) prog.cons [] in
  let cons = List.sort (fun a b -> compare (hex12 a.chash) (hex12 b.chash)) cons in
  List.iter
    (fun cr ->
      line st.decls "const jq_con_info %s = { %d, %d, %d, %s };" (ci_name cr.chash) cr.ctype_id
        cr.cordinal cr.carity (c_string cr.cname))
    cons;
  List.iter (fun cr -> st.declared <- SSet.add ("ci:" ^ hex12 cr.chash) st.declared) cons;
  (* effect op infos, the ordinal-indexed metadata table, and the grant slots *)
  let oplist =
    Hashtbl.fold (fun _ o acc -> o :: acc) prog.ops []
    |> List.sort (fun a b -> compare a.oord b.oord)
  in
  List.iter
    (fun o ->
      line st.decls "const jq_op_info %s = { NULL, %s, %s, %d };" (oi_name o.ohash)
        (c_string o.oeffect) (c_string o.oname) o.oord;
      st.declared <- SSet.add ("oi:" ^ hex12 o.ohash) st.declared)
    oplist;
  let n_ops = List.length oplist in
  line st.decls "static const jq_op_info *jq_op_meta[%d] = { %s };" (max 1 n_ops)
    (if oplist = [] then "NULL"
     else String.concat ", " (List.map (fun o -> "&" ^ oi_name o.ohash) oplist));
  line st.decls "static jq_value (*jq_grant_tbl[%d])(jq_rt *, const jq_value *);" (max 1 n_ops);
  (* the grant natives ported so far (jq_grants.c); --allow parsing in the
     generated main installs these by op name *)
  let implemented =
    [
      ("console", [ ("print", "jq_g_print"); ("read-line", "jq_g_read_line") ]);
      ("clock", [ ("now", "jq_g_now"); ("sleep", "jq_g_sleep") ]);
      ( "fs",
        [ ("read", "jq_g_fs_read"); ("write", "jq_g_fs_write"); ("list-dir", "jq_g_fs_list_dir") ]
      );
    ]
  in
  (* one granted flag per effect a manifest checks, plus the implemented
     grant set (--allow parsing always sets those). An effect discharged
     in-language never reaches a manifest, and its unused flag would be a
     clang warning in the generated unit. *)
  let effects =
    List.sort_uniq compare (List.map fst implemented @ List.concat_map (List.map fst) manifests)
  in
  List.iter (fun e -> line st.decls "static bool g_eff_%s;" (mangle e)) effects;
  (* builtin infos for the implemented intrinsics *)
  List.iter
    (fun (name, arity) ->
      let c = mangle name in
      line st.decls "const jq_builtin_info jq_bi_%s = { 0, %d, %s, jq_i_%s };" c arity
        (c_string name) c;
      st.declared <- SSet.add ("bi:" ^ name) st.declared)
    intrinsics;
  (* init-once cells for const members, in dependency order *)
  let consts =
    List.filter (fun (m : compiled_member) -> m.const_body <> None) prog.members
    |> List.map (fun (m : compiled_member) -> (m.member, m))
  in
  List.iter (fun (h, _) -> line st.decls "jq_value %s;" (cell_name h)) consts;
  List.iter
    (fun ((h, m) : Hash.t * compiled_member) ->
      st.declared <- SSet.add ("cell:" ^ cell_name h) st.declared;
      line st.ub "";
      line st.ub "/* %s */" m.mname;
      line st.ub "static void %s(jq_rt *rt) {" (init_name h);
      st.ub.indent <- st.ub.indent + 1;
      line st.ub "jq_value _r = JQ_UNIT;";
      (match m.const_body with
      | Some body -> emit_expr st st.ub [] (EAssign ("_r", "done_" ^ hex12 h)) body
      | None -> ());
      line st.ub "done_%s:;" (hex12 h);
      line st.ub "%s = _r;" (cell_name h);
      st.ub.indent <- st.ub.indent - 1;
      line st.ub "}")
    consts;
  (* lifted lambdas of const members and of top-level expressions *)
  List.iter
    (fun ((_, m) : Hash.t * compiled_member) -> List.iter (emit_fn st) m.lifted)
    (List.filter (fun ((_, m) : Hash.t * compiled_member) -> m.main_fn = None) consts);
  List.iter (fun (_, lifted, _) -> List.iter (emit_fn st) lifted) prog.tops;
  (* the program body runs on a large-stack thread (deep non-tail recursion
     is deep C recursion here; see runtime/jq_main.c) *)
  line st.ub "";
  line st.ub "static void jq_program(jq_rt *rt) {";
  st.ub.indent <- st.ub.indent + 1;
  line st.ub "rt->op_meta = jq_op_meta;";
  line st.ub "rt->grants = jq_grant_tbl;";
  line st.ub "rt->n_ops = %d;" (Hashtbl.length prog.ops);
  line st.ub "rt->v_true = %s;" (con_value_static st v_true);
  line st.ub "rt->v_false = %s;" (con_value_static st v_false);
  (match orderings with
  | Some (l, e, g) ->
      line st.ub "rt->v_less = %s;" (con_value_static st l);
      line st.ub "rt->v_equal = %s;" (con_value_static st e);
      line st.ub "rt->v_greater = %s;" (con_value_static st g)
  | None -> ());
  (match listcons with
  | Some (nil_h, cons_h) ->
      declare_con_info st cons_h;
      line st.ub "rt->v_nil = %s;" (con_value_static st nil_h);
      line st.ub "rt->ci_cons = &%s;" (ci_name cons_h)
  | None -> ());
  List.iter (fun h -> line st.ub "%s(rt);" (init_name h)) prog.init_order;
  List.iteri
    (fun i (body, _, warnings) ->
      line st.ub "{";
      st.ub.indent <- st.ub.indent + 1;
      (* per-expression: replay build-time warnings, then check THIS expression's
         manifest against the runtime grants, then evaluate and print — matching the
         interpreter's interleaving (earlier output has already flushed when a later
         expression is refused) *)
      List.iter (fun w -> line st.ub "fputs(%s, stderr);" (c_string (w ^ "\n"))) warnings;
      (* every missing grant reports before the single exit — the interpreter
         prints manifest_errors' whole batch, not just the first *)
      (match List.nth manifests i with
      | [] -> ()
      | entries ->
          line st.ub "bool _refused = false;";
          List.iter
            (fun (eff, msg) ->
              line st.ub "if (!g_eff_%s) { fputs(%s, stderr); _refused = true; }" (mangle eff)
                (c_string (msg ^ "\n")))
            entries;
          line st.ub "if (_refused) exit(3);");
      line st.ub "jq_value _v = JQ_UNIT;";
      emit_expr st st.ub [] (EAssign ("_v", Printf.sprintf "done_top_%d" i)) body;
      line st.ub "done_top_%d:;" i;
      (* the flush is parity: the interpreter's per-expression print is OCaml's
         print_endline, which flushes stdout — without it a later expression's
         stderr (warning or refusal) would overtake THIS value in a merged
         capture. Effect output inside evaluation stays buffered on both
         engines (print_string / fwrite), so this is the only flush point. *)
      line st.ub "{ char *s = jq_show(_v); puts(s); free(s); fflush(stdout); }";
      line st.ub "jq_drop(_v);";
      st.ub.indent <- st.ub.indent - 1;
      line st.ub "}")
    prog.tops;
  st.ub.indent <- st.ub.indent - 1;
  line st.ub "}";
  line st.ub "";
  line st.ub "int main(int argc, char **argv) {";
  st.ub.indent <- st.ub.indent + 1;
  line st.ub "jq_rt rt0 = { 0 };";
  line st.ub "for (int i = 1; i < argc; i++) {";
  st.ub.indent <- st.ub.indent + 1;
  (* cmdliner accepts both the space and equals spellings; match it *)
  line st.ub "const char *nm = NULL;";
  line st.ub "if (strncmp(argv[i], \"--allow=\", 8) == 0) nm = argv[i] + 8;";
  line st.ub "else if (strcmp(argv[i], \"--allow\") == 0 && i + 1 < argc) nm = argv[++i];";
  line st.ub "if (!nm) continue;";
  line st.ub "char low[64]; size_t li = 0;";
  line st.ub
    "for (; nm[li] && li < 63; li++) low[li] = nm[li] >= 'A' && nm[li] <= 'Z' ? nm[li] + 32 : \
     nm[li];";
  line st.ub "low[li] = 0;";
  (* implemented grants: install natives for the ops this program actually reaches *)
  List.iter
    (fun (eff, natives) ->
      line st.ub "if (strcmp(low, %s) == 0) {" (c_string eff);
      st.ub.indent <- st.ub.indent + 1;
      line st.ub "g_eff_%s = true;" (mangle eff);
      Hashtbl.iter
        (fun _ o ->
          if o.oeffect = eff then
            match List.assoc_opt o.oname natives with
            | Some native -> line st.ub "jq_grant_tbl[%d] = %s;" o.oord native
            | None -> ())
        prog.ops;
      line st.ub "continue;";
      st.ub.indent <- st.ub.indent - 1;
      line st.ub "}")
    implemented;
  line st.ub
    "fprintf(stderr, \"error[E1103]: native binaries implement only the console, clock, and fs \
     grants so far (task 70); cannot grant `%%s`\\n\", nm);";
  line st.ub "return 1;";
  st.ub.indent <- st.ub.indent - 1;
  line st.ub "}";
  line st.ub "return jq_run_main(&rt0, jq_program);";
  st.ub.indent <- st.ub.indent - 1;
  line st.ub "}";
  assemble st ~banner:"/* generated by jacquard build (task 67) — program main; do not edit */\n"
