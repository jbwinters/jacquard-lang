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
  oeffect_hash : Hash.t;
  oeffect : string;
  oname : string;
  omode : Kernel.op_mode;
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
  framed_fns : (Hash.t * int, unit) Hashtbl.t;
      (** fns that compile frame-style (task 71): they may suspend, so they carry the resume-point
          machine — build.ml's classification fixed-point fills this *)
  framed_members : (Hash.t, unit) Hashtbl.t;
      (** members whose entry fn is framed: a known call to one is a suspendable site *)
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

let effect_flag (identity : Hash.t) = "g_eff_" ^ Hash.to_hex identity

let canonical_effect_hash index_name =
  match
    List.find_opt
      (fun (metadata : Effect_registry.metadata) -> metadata.index_name = index_name)
      (Effect_registry.entries Effect_registry.canonical)
  with
  | Some { interface = Released { hash; _ }; _ } -> hash
  | Some { interface = Reserved _; _ } | None ->
      invalid_arg ("native grant has no released canonical effect identity: " ^ index_name)

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
  mutable precise : bool;
      (** Perceus ran (task 68): moves and Drop nodes own every count; the emitter adds no
          exit-point drops of its own. False = the naive skeleton discipline. *)
  ub : buf;  (** unit body: functions *)
  decls : buf;  (** extern declarations and unit-local statics, emitted first *)
  mutable declared : SSet.t;  (** dedup for externs/statics *)
  mutable statics : int;  (** unit-local static counter (texts, reals, values) *)
  mutable fr : fr_state option;
      (** Some while emitting a frame-style function body (task 71): NIR locals hoist to the
          function top (so the re-entry switch can restore them before jumping), and each
          suspendable site records a resume point *)
}

and fr_state = {
  re_name : string;  (** the jq_frame_fn wrapper's C name *)
  mutable rps : (int * string * string list) list;
      (** resume points: (index, result local, saved locals — the lives at the site, restored in
          order at re-entry) *)
  mutable next_rp : int;
  mutable hoisted : string list;  (** locals to declare at the top, reverse order *)
}
(** per-function frame-machine bookkeeping *)

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

(* static code trees (task 73): one immortal block per distinct subtree,
   deduped by a serialization key. Children emit before parents so the
   forward references resolve. *)
let hash_static st (h : Hash.t) =
  let hex = Hash.to_hex h in
  let name = "hs_" ^ String.sub hex 0 12 in
  declare st ("hs:" ^ name) (fun () ->
      let bytes = Hash.to_raw h in
      let words =
        List.init 32 (fun i -> Printf.sprintf "0x%02x" (Char.code (String.get bytes i)))
      in
      line st.decls
        "static const struct { uint32_t rc; uint8_t tag; uint8_t flags; uint16_t n; \
         uint8_t          bytes[32]; }";
      line st.decls "  %s = { UINT32_MAX, JQ_HASH, 0, 4, { %s } };" name (String.concat ", " words));
  Printf.sprintf "((jq_value)&%s)" name

let int_word (i : int) : string =
  Printf.sprintf "%LuULL" (Int64.logor (Int64.shift_left (Int64.of_int i) 1) 1L)

let rec code_ser (t : code_tmpl) : string =
  Printf.sprintf "F%d:%s(%s)" (String.length t.chead) t.chead
    (String.concat ","
       (List.map
          (function
            | CForm sub -> code_ser sub
            | CInt i -> Printf.sprintf "I%d" i
            | CReal r -> Printf.sprintf "R%Lx" (Int64.bits_of_float r)
            | CText x -> Printf.sprintf "T%d:%s" (String.length x) x
            | CSym x -> Printf.sprintf "S%d:%s" (String.length x) x
            | CHash h -> "H" ^ Hash.to_hex h
            | CSplice _ -> failwith "internal: splice in a static code tree")
          t.cargs))

let rec code_static st (t : code_tmpl) : string =
  let head = text_static st t.chead in
  let args =
    List.map
      (function
        | CForm sub -> ("JQ_CA_FORM", code_static st sub)
        | CInt i -> ("JQ_CA_INT", int_word i)
        | CReal r -> ("JQ_CA_REAL", real_static st r)
        | CText x -> ("JQ_CA_TEXT", text_static st x)
        | CSym x -> ("JQ_CA_SYM", text_static st x)
        | CHash h -> ("JQ_CA_HASH", hash_static st h)
        | CSplice _ -> failwith "internal: splice in a static code tree")
      t.cargs
  in
  let name = "cq_" ^ String.sub (Hash.to_hex (Hash.of_string (code_ser t))) 0 12 in
  declare st ("cq:" ^ name) (fun () ->
      let payload =
        Printf.sprintf "(uint64_t)%s" head
        :: List.concat_map (fun (k, v) -> [ k; Printf.sprintf "(uint64_t)%s" v ]) args
      in
      emit_static_block st name ~tag:"JQ_CODE" ~flags:0
        ~n:(1 + (2 * List.length args))
        ~payload_words:(1 + (2 * List.length args))
        ~payload);
  Printf.sprintf "((jq_value)&%s)" name

let rec code_has_splice (a : code_arg) : bool =
  match a with CSplice _ -> true | CForm t -> List.exists code_has_splice t.cargs | _ -> false

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

(* vars a bound consumes by move: they leave the owned-live set at this
   binding, so a frame save at or after it must not capture them (task 82) *)
let moved_vars (b : bound) : string list =
  let atoms =
    match b with
    | BAtom a -> [ a ]
    | BCallKnown (_, args) | BIntrinsic (_, args) | BAllocTuple args | BAllocCode (_, args) -> args
    | BCallUnknown (f, args) -> f :: args
    | BAllocCon (_, args) | BAllocConReuse (_, args, _) | BPerform (_, args) -> args
    | BAllocClosure { captured; _ } -> captured
    | BHandle (entries, thunk, retc) -> thunk :: retc :: List.map (fun (_, _, a) -> a) entries
  in
  List.filter_map (function AMove (AVar x) -> Some x | _ -> None) atoms

(* A use: the receiver takes ownership, so dup (no-op for ints and statics). *)
let use st buf (a : atom) : string =
  match a with
  | AInt _ -> atom_c st a
  | AMove inner -> atom_c st inner (* ownership transfers: Perceus proved the last use *)
  | _ ->
      let e = atom_c st a in
      line buf "jq_dup(%s);" e;
      e

(* An NIR-named local's declaration site: frame-style functions hoist the declaration
   to the function top so the re-entry switch can assign it before jumping; the site
   then emits a plain assignment. *)
let decl_prefix st (x : string) : string =
  match st.fr with
  | Some fr ->
      fr.hoisted <- x :: fr.hoisted;
      ""
  | None -> "jq_value "

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
      line buf "%s%s = %s;" (decl_prefix st x) x subject;
      line buf "jq_dup(%s);" x;
      [ x ]
  | NPAs (x, inner) ->
      line buf "%s%s = %s;" (decl_prefix st x) x subject;
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
    List.iter (fun t -> line buf "if (%s) jq_block_free(%s);" t t) tokens
  in
  match e with
  | LetReuse (tok, x, _, body) ->
      line buf "jq_block *%s = jq_reuse_take(%s);" tok x;
      emit_expr ~tokens:(tok :: tokens) st buf lives exit body
  | Drop (xs, body) ->
      List.iter (fun x -> line buf "jq_drop(%s);" x) xs;
      emit_expr ~tokens st buf (List.filter (fun l -> not (List.mem l xs)) lives) exit body
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
      let moved = moved_vars b in
      let lives_at_site = List.filter (fun l -> not (List.mem l moved)) lives in
      emit_bound st buf lives_at_site x b;
      emit_expr ~tokens st buf (x :: lives_at_site) exit body
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
      List.iter (fun t -> line buf "if (%s) jq_block_free(%s);" t t) tokens;
      List.iteri (fun i t -> line buf "a%d = %s;" i t) temps;
      match exit with
      | EReturn -> line buf "goto entry;"
      | EAssign _ ->
          (* top-level expressions have no self *)
          line buf "goto entry;")
  | TailKnown (code, args, post) ->
      let fname = fn_name code in
      declare st ("fn:" ^ fname) (fun () -> line st.decls "extern jq_value %s(JQ_PARAMS);" fname);
      emit_tail_call st buf lives exit ~post ~tokens ~target:(fname, "JQ_UNIT") args
  | TailUnknown (f, args, post) ->
      let fv = use st buf f in
      let t = "_f" in
      line buf "jq_value %s = %s;" t fv;
      line buf "rt->apply_n = %d;" (List.length args);
      emit_tail_call st buf (t :: lives) exit ~consumes:[ t ] ~post ~tokens ~target:("jq_apply", t)
        args

and emit_tail_call st buf lives exit ?(consumes = []) ?(post = []) ?(tokens = [])
    ~(target : string * string) (args : atom list) : unit =
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
  List.iter (fun t -> line buf "if (%s) jq_block_free(%s);" t t) tokens;
  let padded =
    temps @ List.init (max_arity - List.length temps) (fun _ -> "JQ_UNIT") |> String.concat ", "
  in
  let f, c = target in
  match exit with
  | EReturn ->
      (* JQ_TAIL_RETURN musttails where the toolchain can and stashes for the
         trampoline where it cannot (task 83); the emitted C is identical *)
      line buf "JQ_TAIL_RETURN(%s, rt, %s, %s);" f c padded
  | EAssign (var, label) ->
      line buf "%s = %s(rt, %s, %s);" var f c padded;
      line buf "%s = JQ_HOP(rt, %s);" var var;
      line buf "goto %s;" label

(* task 71: a suspendable site in a frame-style function — when a capture is possible
   (rt->cap_depth > 0), save the live locals into this activation's frame and link it
   before the call; a JQ_SUSPEND result propagates immediately (the frame stays for
   the capture slice); a normal return unlinks and frees the frame. The recorded
   resume point re-enters right after the site with the call's result substituted. *)
and emit_suspendable st buf (lives : string list) (x : string) (emit_call : unit -> unit) : unit =
  match st.fr with
  | None -> emit_call ()
  | Some fr ->
      fr.next_rp <- fr.next_rp + 1;
      let ix = fr.next_rp in
      fr.rps <- (ix, x, lives) :: fr.rps;
      line buf "if (rt->cap_depth) {";
      buf.indent <- buf.indent + 1;
      line buf "_fr = jq_frame_alloc(%s, %d, 0, %d);" fr.re_name ix (List.length lives);
      List.iteri (fun i l -> line buf "jq_frame_slots(_fr)[%d] = %s;" i l) lives;
      line buf "jq_ks_push(rt, _fr);";
      buf.indent <- buf.indent - 1;
      line buf "} else _fr = NULL;";
      emit_call ();
      line buf "if (%s == JQ_SUSPEND) return JQ_SUSPEND;" x;
      line buf "if (_fr) { jq_ks_pop(rt); jq_block_free(_fr); }";
      line buf "rp_%d:;" ix

and emit_bound st buf lives (x : string) (b : bound) : unit =
  match b with
  | BAtom a ->
      let v = use st buf a in
      line buf "%s%s = %s;" (decl_prefix st x) x v
  | BCallKnown (code, args) ->
      let fname = fn_name code in
      declare st ("fn:" ^ fname) (fun () -> line st.decls "extern jq_value %s(JQ_PARAMS);" fname);
      let call () =
        let vs = List.map (fun a -> use st buf a) args in
        let padded =
          vs @ List.init (max_arity - List.length vs) (fun _ -> "JQ_UNIT") |> String.concat ", "
        in
        line buf "%s%s = %s(rt, JQ_UNIT, %s);" (decl_prefix st x) x fname padded;
        line buf "%s = JQ_HOP(rt, %s);" x x
      in
      if Hashtbl.mem st.prog.framed_fns code then emit_suspendable st buf lives x call else call ()
  | BCallUnknown (f, args) ->
      emit_suspendable st buf lives x (fun () ->
          let fv = use st buf f in
          let vs = List.map (fun a -> use st buf a) args in
          let padded =
            vs @ List.init (max_arity - List.length vs) (fun _ -> "JQ_UNIT") |> String.concat ", "
          in
          line buf "rt->apply_n = %d;" (List.length args);
          line buf "%s%s = jq_apply(rt, %s, %s);" (decl_prefix st x) x fv padded;
          line buf "%s = JQ_HOP(rt, %s);" x x)
  | BAllocCon (h, args) ->
      declare_con_info st h;
      let vs = List.map (fun a -> use st buf a) args in
      if vs = [] then line buf "%s%s = jq_con(&%s, NULL);" (decl_prefix st x) x (ci_name h)
      else
        line buf "%s%s = jq_con(&%s, (jq_value[]){ %s });" (decl_prefix st x) x (ci_name h)
          (String.concat ", " vs)
  | BAllocConReuse (h, args, tok) ->
      declare_con_info st h;
      let vs = List.map (fun a -> use st buf a) args in
      line buf "%s%s = jq_con_reuse(%s, &%s, (jq_value[]){ %s });" (decl_prefix st x) x tok
        (ci_name h) (String.concat ", " vs);
      line buf "%s = NULL;" tok
  | BAllocTuple args ->
      let vs = List.map (fun a -> use st buf a) args in
      if vs = [] then line buf "%s%s = JQ_UNIT;" (decl_prefix st x) x
      else
        line buf "%s%s = jq_tuple(%d, (jq_value[]){ %s });" (decl_prefix st x) x (List.length vs)
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
      line buf "%s%s = jq_closure((void *)&%s, %d, %d, %s, %s);" (decl_prefix st x) x fname arity
        (List.length captured) env
        (match self_slot with Some i -> string_of_int i | None -> "UINT16_MAX");
      match self_slot with Some i -> line buf "jq_closure_env(%s)[%d] = %s;" x i x | None -> ())
  | BIntrinsic (name, args) ->
      let vs = List.map (fun a -> use st buf a) args in
      let cname = mangle name in
      if String.equal name "text.join-variadic-v1" then
        line buf "%s%s = jq_i_%s(rt, %s, %d);" (decl_prefix st x) x cname
          (if vs = [] then "NULL" else Printf.sprintf "(jq_value[]){ %s }" (String.concat ", " vs))
          (List.length vs)
      else if vs = [] then line buf "%s%s = jq_i_%s(rt, NULL);" (decl_prefix st x) x cname
      else
        line buf "%s%s = jq_i_%s(rt, (jq_value[]){ %s });" (decl_prefix st x) x cname
          (String.concat ", " vs)
  | BAllocCode (root, args) ->
      if not (code_has_splice root) then begin
        (* the whole payload is static: bind the immortal tree, no RC *)
        let t = match root with CForm t -> t | _ -> failwith "internal: splice-free root" in
        line buf "%s%s = %s;" (decl_prefix st x) x (code_static st t)
      end
      else begin
        (* splice results are guarded (must be code) then consumed into their
           holes; splice-free subtrees stay immortal statics. Temps never
           live across a resume point (nothing here suspends). *)
        let svals = List.map (fun a -> use st buf a) args in
        let guarded =
          List.mapi
            (fun i v ->
              let g = Printf.sprintf "_q%s_%d" x i in
              line buf "jq_value %s = jq_code_splice_guard(rt, %s);" g v;
              g)
            svals
        in
        let ctr = ref 0 in
        let rec build (a : code_arg) : string =
          match a with
          | CSplice i -> List.nth guarded i
          | _ when not (code_has_splice a) -> (
              match a with
              | CForm t -> code_static st t
              | CInt i -> Printf.sprintf "jq_int(%dLL)" i
              | CReal r -> real_static st r
              | CText t -> text_static st t
              | CSym t -> text_static st t
              | CHash h -> hash_static st h
              | CSplice _ -> assert false)
          | CForm t ->
              (* a spine node containing splices: build children first *)
              let parts =
                List.map
                  (fun arg ->
                    let kind =
                      match arg with
                      | CForm _ -> "JQ_CA_FORM"
                      | CInt _ -> "JQ_CA_INT"
                      | CReal _ -> "JQ_CA_REAL"
                      | CText _ -> "JQ_CA_TEXT"
                      | CSym _ -> "JQ_CA_SYM"
                      | CHash _ -> "JQ_CA_HASH"
                      | CSplice _ -> "JQ_CA_FORM"
                    in
                    (kind, build arg))
                  t.cargs
              in
              let n = Printf.sprintf "_qn%s_%d" x !ctr in
              incr ctr;
              line buf "jq_value %s = jq_code_node(%s, %d);" n (text_static st t.chead)
                (List.length parts);
              List.iteri
                (fun i (kind, v) -> line buf "jq_code_set(%s, %d, %s, %s);" n i kind v)
                parts;
              n
          | CInt _ | CReal _ | CText _ | CSym _ | CHash _ -> assert false
        in
        let result = build root in
        line buf "%s%s = %s;" (decl_prefix st x) x result
      end
  | BPerform (h, args) ->
      let oref = Hashtbl.find st.prog.ops h in
      emit_suspendable st buf lives x (fun () ->
          let vs = List.map (fun a -> use st buf a) args in
          if vs = [] then
            line buf "%s%s = jq_perform(rt, %d, 0, NULL);" (decl_prefix st x) x oref.oord
          else
            line buf "%s%s = jq_perform(rt, %d, %d, (jq_value[]){ %s });" (decl_prefix st x) x
              oref.oord (List.length vs) (String.concat ", " vs))
  | BHandle (entries, thunk, retc) ->
      (* jq_handle2 owns the entry clauses, the thunk, and the ret closure; it pushes its
         handler frame + entries, runs the thunk, and dispatches captures (task 71) *)
      emit_suspendable st buf lives x (fun () ->
          let evs =
            List.map
              (fun (oh, capturing, a) ->
                let oref = Hashtbl.find st.prog.ops oh in
                Printf.sprintf "{ .op_ord = %d, .clause = %s, .kind = %s, .once = %s }" oref.oord
                  (use st buf a)
                  (if capturing then "JQ_CLAUSE_CAPTURING" else "JQ_CLAUSE_TAIL")
                  (match oref.omode with Kernel.Multi -> "false" | Kernel.Once -> "true"))
              entries
          in
          line buf "jq_handler_entry _he_%s[] = { %s };" x (String.concat ", " evs);
          let tv = use st buf thunk in
          let rv = use st buf retc in
          line buf "%s%s = jq_handle2(rt, %d, _he_%s, %s, %s);" (decl_prefix st x) x
            (List.length entries) x tv rv)

(* ------------------------------------------------------------------ *)
(* Functions                                                           *)
(* ------------------------------------------------------------------ *)

(* prologue: bind parameter patterns; failure reproduces the interpreter's Match_failure *)
let emit_prologue st buf (f : fn) : string list =
  let lives = ref [ "clo" ] in
  List.iteri
    (fun i p ->
      let subject = Printf.sprintf "a%d" i in
      lives := subject :: !lives;
      match p with
      | NPVar x ->
          (* the param IS the local: transfer ownership, no dup *)
          line buf "%s%s = %s;" (decl_prefix st x) x subject;
          lives := x :: List.filter (fun l -> l <> subject) !lives
      | NPWild -> ()
      | _ ->
          let tests = pat_test st subject p in
          let cond = if tests = [] then "1" else String.concat " && " tests in
          line buf "if (!(%s)) jq_match_fail(rt, %s);" cond subject;
          let binds = pat_bind st buf subject p in
          lives := List.rev_append binds !lives)
    f.params;
  !lives

let emit_fn st (f : fn) : unit =
  let buf = st.ub in
  if not (Hashtbl.mem st.prog.framed_fns f.fname) then begin
    line buf "";
    line buf "jq_value %s(JQ_PARAMS) {" (fn_name f.fname);
    buf.indent <- buf.indent + 1;
    line buf "(void)rt; (void)clo;";
    (* silence unused padding args *)
    for i = f.n_params to max_arity - 1 do
      line buf "(void)a%d;" i
    done;
    if f.self_entry then line buf "entry:;";
    let lives = emit_prologue st buf f in
    emit_expr st buf lives EReturn f.body;
    buf.indent <- buf.indent - 1;
    line buf "}"
  end
  else begin
    (* frame-style machine (task 71): NIR locals hoist to the top so the re-entry
       switch can restore them and jump to the recorded resume point; the wrapper
       hands the frame over through rt. Naive RC discipline throughout — a
       suspension abandons the in-scope locals to the frame. *)
    let re_name = fn_name f.fname ^ "_re" in
    let fr = { re_name; rps = []; next_rp = 0; hoisted = [] } in
    st.fr <- Some fr;
    let body_buf = { b = Buffer.create 2048; indent = 1 } in
    if f.self_entry then line body_buf "entry:;";
    let lives = emit_prologue st body_buf f in
    emit_expr st body_buf lives EReturn f.body;
    st.fr <- None;
    line buf "";
    (* a fn framed only through TAIL calls has no resume points: the sentinel just
       passes through its return, so no wrapper or switch is needed *)
    if fr.rps <> [] then
      line buf "static jq_value %s(jq_rt *rt, jq_block *_f, jq_value _v);" re_name;
    line buf "jq_value %s(JQ_PARAMS) {" (fn_name f.fname);
    buf.indent <- buf.indent + 1;
    line buf "(void)rt; (void)clo;";
    for i = f.n_params to max_arity - 1 do
      line buf "(void)a%d;" i
    done;
    line buf "jq_block *_fr = NULL; (void)_fr;";
    (match List.sort_uniq compare fr.hoisted with
    | [] -> ()
    | hs -> line buf "jq_value %s;" (String.concat ", " hs));
    if fr.rps <> [] then begin
      line buf "if (rt->re_frame) {";
      buf.indent <- buf.indent + 1;
      line buf "jq_block *_f0 = rt->re_frame;";
      line buf "rt->re_frame = NULL;";
      line buf "jq_value _in = rt->re_val;";
      line buf "switch ((int)jq_frame_ix(_f0)) {";
      List.iter
        (fun (ix, res, saved) ->
          line buf "case %d:" ix;
          buf.indent <- buf.indent + 1;
          List.iteri (fun i l -> line buf "%s = jq_frame_slots(_f0)[%d];" l i) saved;
          line buf "jq_block_free(_f0);";
          line buf "%s = _in;" res;
          line buf "goto rp_%d;" ix;
          buf.indent <- buf.indent - 1)
        (List.rev fr.rps);
      line buf "default:;";
      line buf "}";
      line buf "fputs(\"jacquard runtime: unknown resume point (internal)\\n\", stderr);";
      line buf "exit(2);";
      buf.indent <- buf.indent - 1;
      line buf "}"
    end;
    Buffer.add_buffer buf.b body_buf.b;
    buf.indent <- buf.indent - 1;
    line buf "}";
    if fr.rps <> [] then begin
      line buf "static jq_value %s(jq_rt *rt, jq_block *_f, jq_value _v) {" re_name;
      buf.indent <- buf.indent + 1;
      line buf "rt->re_frame = _f;";
      line buf "rt->re_val = _v;";
      line buf
        "return %s(rt, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, \
         JQ_UNIT);"
        (fn_name f.fname);
      buf.indent <- buf.indent - 1;
      line buf "}"
    end
  end

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
    fr = None;
  }

let assemble st ~banner =
  let out = Buffer.create (Buffer.length st.decls.b + Buffer.length st.ub.b + 256) in
  Buffer.add_string out banner;
  Buffer.add_string out
    "#include \"jq_value.h\"\n\n\
     #include <stdio.h>\n\
     #include <stdlib.h>\n\
     #include <string.h>\n\
     #include <time.h>\n\n";
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
      (Printf.sprintf
         "/* Generated by jacquard build: declaration %s. User-authored code and this output may be\n\
          * licensed under terms chosen by the user; see RUNTIME-EXCEPTION.md. Do not edit. */\n"
         decl_hex)

(** The main unit: constructor infos, builtin infos, init-once cells, and the per-expression driver
    with the interpreter's output and exit-code contract. *)
let main_source (prog : program) ~precise ~(v_true : Hash.t) ~(v_false : Hash.t)
    ~(option_cons : (Hash.t * Hash.t) option) ~(orderings : (Hash.t * Hash.t * Hash.t) option)
    ~(result_cons : (Hash.t * Hash.t) option) ~(listcons : (Hash.t * Hash.t) option)
    ~(pair : Hash.t option) ~(intrinsics : (string * int) list)
    ~(manifests : (Hash.t * string) list list) : string =
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
      ( "console",
        canonical_effect_hash "console",
        [ ("print", "jq_g_print"); ("read-line", "jq_g_read_line") ] );
      ("clock", canonical_effect_hash "clock", [ ("now", "jq_g_now"); ("sleep", "jq_g_sleep") ]);
      ( "fs",
        canonical_effect_hash "fs",
        [ ("read", "jq_g_fs_read"); ("write", "jq_g_fs_write"); ("list-dir", "jq_g_fs_list_dir") ]
      );
      ( "dist",
        canonical_effect_hash "dist",
        [ ("sample", "jq_g_dist_sample"); ("observe", "jq_g_dist_observe") ] );
      ("infer", canonical_effect_hash "infer", [ ("complete", "jq_g_infer_complete") ]);
    ]
  in
  (* one granted flag per effect a manifest checks, plus the implemented
     grant set (--allow parsing always sets those). An effect discharged
     in-language never reaches a manifest, and its unused flag would be a
     clang warning in the generated unit. *)
  let effects =
    List.sort_uniq Hash.compare
      (List.map (fun (_, identity, _) -> identity) implemented
      @ List.concat_map (List.map fst) manifests)
  in
  List.iter (fun identity -> line st.decls "static bool %s;" (effect_flag identity)) effects;
  (* builtin infos for the implemented intrinsics *)
  List.iter
    (fun (name, arity) ->
      let c = mangle name in
      if arity < 0 then
        line st.decls "const jq_builtin_info jq_bi_%s = { 0, UINT32_MAX, %s, NULL };" c
          (c_string name)
      else
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
  (* Const-member lifted lambdas live in their declaration unit. Emitting them again here would
     create duplicate symbols once a previously refused intrinsic makes that const reachable. *)
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
  (match pair with
  | Some pair_h ->
      declare_con_info st pair_h;
      line st.ub "rt->ci_pair = &%s;" (ci_name pair_h)
  | None -> ());
  (match option_cons with
  | Some (some_h, none_h) ->
      declare_con_info st some_h;
      line st.ub "rt->ci_some = &%s;" (ci_name some_h);
      line st.ub "rt->v_none = %s;" (con_value_static st none_h)
  | None -> ());
  (match result_cons with
  | Some (ok_h, err_h) ->
      declare_con_info st ok_h;
      declare_con_info st err_h;
      line st.ub "rt->ci_ok = &%s;" (ci_name ok_h);
      line st.ub "rt->ci_err = &%s;" (ci_name err_h)
  | None -> ());
  (* dist ordinals (task 72): the LW driver and the root sampler dispatch by
     these; UINT32_MAX when the program reaches neither op *)
  let dist_identity = canonical_effect_hash "dist" in
  let dist_ord name =
    Hashtbl.fold
      (fun _ o acc ->
        if Hash.equal o.oeffect_hash dist_identity && o.oname = name then Some o.oord else acc)
      prog.ops None
  in
  line st.ub "rt->ord_sample = %s;"
    (match dist_ord "sample" with Some i -> string_of_int i | None -> "UINT32_MAX");
  line st.ub "rt->ord_observe = %s;"
    (match dist_ord "observe" with Some i -> string_of_int i | None -> "UINT32_MAX");
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
              line st.ub "if (!%s) { fputs(%s, stderr); _refused = true; }" (effect_flag eff)
                (c_string (msg ^ "\n")))
            entries;
          line st.ub "if (_refused) exit(3);");
      line st.ub "jq_value _v = JQ_UNIT;";
      emit_expr st st.ub [] (EAssign ("_v", Printf.sprintf "done_top_%d" i)) body;
      line st.ub "done_top_%d:;" i;
      (* a capture always resolves inside its expression (any capturing handler is
         within it); a sentinel here is an internal bug, never a semantic outcome *)
      line st.ub
        "if (_v == JQ_SUSPEND) { fputs(\"jacquard runtime: a capture escaped its expression \
         (internal)\\n\", stderr); exit(2); }";
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
  (* the sampling grant's stream: OS-entropy seeded unless --seed pins it,
     like run_cmd (a pinned seed is the reproducibility contract; entropy
     quality is irrelevant, unseeded runs are random either way) *)
  line st.ub "rt0.dist_rng = (int64_t)time(NULL) * 1000003 ^ (int64_t)clock();";
  line st.ub "for (int i = 1; i < argc; i++) {";
  st.ub.indent <- st.ub.indent + 1;
  (* cmdliner accepts both the space and equals spellings; match it *)
  line st.ub "const char *sd = NULL;";
  line st.ub "if (strncmp(argv[i], \"--seed=\", 7) == 0) sd = argv[i] + 7;";
  line st.ub "else if (strcmp(argv[i], \"--seed\") == 0 && i + 1 < argc) sd = argv[++i];";
  line st.ub "if (sd) { rt0.dist_rng = strtoll(sd, NULL, 10); continue; }";
  (* the completion cache's entry format needs the reader; loud, not silent *)
  line st.ub "if (strncmp(argv[i], \"--infer-cache\", 13) == 0) {";
  st.ub.indent <- st.ub.indent + 1;
  line st.ub
    "fputs(\"error[E1103]: native binaries do not cache completions yet (the cache entry format \
     needs task 73's reader); rerun without --infer-cache\\n\", stderr);";
  line st.ub "return 1;";
  st.ub.indent <- st.ub.indent - 1;
  line st.ub "}";
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
    (fun (eff, identity, natives) ->
      line st.ub "if (strcmp(low, %s) == 0) {" (c_string eff);
      st.ub.indent <- st.ub.indent + 1;
      line st.ub "%s = true;" (effect_flag identity);
      Hashtbl.iter
        (fun _ o ->
          if Hash.equal o.oeffect_hash identity then
            match List.assoc_opt o.oname natives with
            | Some native -> line st.ub "jq_grant_tbl[%d] = %s;" o.oord native
            | None -> ())
        prog.ops;
      line st.ub "continue;";
      st.ub.indent <- st.ub.indent - 1;
      line st.ub "}")
    implemented;
  line st.ub
    "fprintf(stderr, \"error[E1103]: native binaries implement only the console, clock, fs, dist, \
     and infer grants so far (task 72); cannot grant `%%s`\\n\", nm);";
  line st.ub "return 1;";
  st.ub.indent <- st.ub.indent - 1;
  line st.ub "}";
  line st.ub "return jq_run_main(&rt0, jq_program);";
  st.ub.indent <- st.ub.indent - 1;
  line st.ub "}";
  assemble st
    ~banner:
      "/* Generated by jacquard build: program main. User-authored code and this output may be\n\
       * licensed under terms chosen by the user; see RUNTIME-EXCEPTION.md. Do not edit. */\n"
