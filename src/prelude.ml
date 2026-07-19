(** Prelude v1 (plan W2.6): the library the kernel keeps out of the language.

    [load] reads every `.jqd` file in a prelude directory (sorted by file name), runs each
    declaration through validate-resolve-put against the store's evolving name index, and returns
    the per-file hashes (golden-pinned by tests). [wire_builtins] registers the native
    implementations of the builtin marker terms (see prelude/04-builtins.jqd) under their store
    hashes; comparison builtins return the prelude's own [bool] constructors.

    Root handlers are the capability grants (spec §7: no ambient handlers): [install_console] grants
    the [console] effect (its [print] op writes through [out] and resumes with unit); [install_eval]
    grants the [eval] effect (its [eval-code] op validates, resolves, and evaluates a [VCode]
    payload at the boundary — the dynamic check the spec pins for M0). [grant] maps a
    case-insensitive effect name from the CLI to the matching installer. Pure effects (abort etc.)
    deliberately has no root handler: an unhandled [abort] is supposed to die. *)

let diagnostic_summary = function
  | "E0701" -> "Prelude directory is unavailable"
  | "E0702" -> "Prelude contents are incomplete or have the wrong kind"
  | "E0703" -> "Requested effect is not root-grantable"
  | code -> "Prelude loading failed (" ^ code ^ ")"

let diagnostic_next_step = function
  | "E0701" -> "Pass --prelude with the path to a complete prelude directory."
  | "E0702" -> "Restore the named declaration with the required prelude kind."
  | "E0703" -> "Handle this effect inside the program instead of granting it at the root."
  | _ -> "Correct the prelude configuration and try again."

let err ~code fmt =
  Printf.ksprintf
    (fun cause ->
      Error
        [
          Diag.error ~domain:Prelude ~code ~summary:(diagnostic_summary code) ~cause
            ~next_step:(diagnostic_next_step code) ~contrast:None ();
        ])
    fmt

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(** [load ~dir store] loads the prelude sources into [store]. Returns
    [(relative file name, hashes of each declaration in file order)] per file, in load order. Fails
    with the first diagnostic batch (E0701 wraps IO problems). *)
let load ~dir store : ((string * Canon.decl_hashes list) list, Diag.t list) result =
  if not (Sys.file_exists dir && Sys.is_directory dir) then
    err ~code:"E0701" "prelude directory %s does not exist" dir
  else
    let files =
      Sys.readdir dir |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jqd")
      |> List.sort String.compare
    in
    let load_file file =
      let path = Filename.concat dir file in
      match Reader.parse_string ~file:path (read_file path) with
      | Error ds -> Error ds
      | Ok forms ->
          let rec go acc = function
            | [] -> Ok (List.rev acc)
            | f :: rest -> (
                match Kernel.decl_of_form f with
                | Error ds -> Error ds
                | Ok d -> (
                    match Resolve.resolve_decl (Store.names_view store) d with
                    | Error ds -> Error ds
                    | Ok d -> (
                        match Store.put_decl store d with
                        | Error ds -> Error ds
                        | Ok hs -> go (hs :: acc) rest)))
          in
          go [] forms
    in
    let rec go acc = function
      | [] ->
          List.iter
            (fun name ->
              match Store.lookup_kind store name Resolve.KCon with
              | Some { Resolve.hash; _ } -> Store.hide_derived store hash
              | None -> ())
            [ "hash-opaque"; "secret-opaque" ];
          (match Store.lookup_kind store "audit-sequence-v0" Resolve.KCon with
          | Some { Resolve.hash; _ } -> Store.hide_derived store hash
          | None -> ());
          List.iter
            (fun name ->
              match Store.lookup_kind store name Resolve.KTerm with
              | Some { Resolve.hash; _ } -> Store.hide_derived store hash
              | None -> ())
            [ "governance.fresh-audit-run-id"; "governance.require-audit-run-id" ];
          let bind_operation_alias effect_name operation_name alias =
            match Store.lookup_kind store effect_name Resolve.KEffect with
            | None -> err ~code:"E0702" "prelude effect `%s` is missing" effect_name
            | Some { Resolve.hash = effect_hash; _ } -> (
                match Store.locate store effect_hash with
                | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; decl_hash; _ }
                  -> (
                    let rec find ordinal = function
                      | [] -> None
                      | (operation : Kernel.opspec) :: rest ->
                          if operation.op_name = operation_name then Some ordinal
                          else find (ordinal + 1) rest
                    in
                    match find 0 ops with
                    | Some ordinal -> Store.bind_name store alias (Canon.op_hash decl_hash ordinal)
                    | None ->
                        err ~code:"E0702" "prelude effect `%s` has no `%s` operation" effect_name
                          operation_name)
                | Ok _ -> err ~code:"E0702" "prelude name `%s` is not an effect" effect_name
                | Error diagnostics -> Error diagnostics)
          in
          let ( let* ) = Result.bind in
          (* Kernel names are flat. Keep the long-standing bare [read] spelling for Fs while
             exposing the collision-free ratified Secret spellings. The declaration still carries
             the exact operation names [read]/[expose], so its interface identity is unchanged. *)
          let* () = bind_operation_alias "secret" "read" "secret.read" in
          let* () = bind_operation_alias "secret" "expose" "secret.expose" in
          let* () = bind_operation_alias "fs" "read" "read" in
          let* () = bind_operation_alias "workspace" "read-file" "workspace.read-file" in
          let* () = bind_operation_alias "workspace" "write-file" "workspace.write-file" in
          let* () = bind_operation_alias "workspace" "fetch" "workspace.fetch" in
          let* () = bind_operation_alias "net" "fetch" "fetch" in
          Ok (List.rev acc)
      | file :: rest -> (
          match load_file file with
          | Error ds -> Error ds
          | Ok hashes -> go ((file, hashes) :: acc) rest)
    in
    go [] files

let lookup_hash store ~kind name : (Hash.t, Diag.t list) result =
  match Store.lookup_kind store name kind with
  | Some { Resolve.hash; _ } -> Ok hash
  | None -> (
      match Store.lookup_name store name with
      | Some _ -> err ~code:"E0702" "prelude name `%s` has an unexpected kind" name
      | None -> err ~code:"E0702" "prelude name `%s` is not in the store" name)

(** Byte offsets where codepoints start, plus the terminal offset (SL.5, D9 semantics: the
    hand-rolled UTF-8 decoder the text builtins share). The second-byte range checks follow the
    Unicode well-formedness table, so overlongs (E0 80-9F, F0 80-8F), surrogates (ED A0-BF), and
    beyond-U+10FFFF (F4 90-BF) are malformed and count one codepoint PER BYTE, same as truncated
    sequences. Module-level so the native parity kit goldens generate from the same decoder
    (docs/native-plan.md, task 66). *)
let utf8_boundaries s =
  let n = String.length s in
  let byte j = if j < n then Char.code s.[j] else -1 in
  let cont j = byte j land 0xC0 = 0x80 && j < n in
  let second_ok b0 b1 =
    match b0 with
    | 0xE0 -> b1 >= 0xA0 && b1 <= 0xBF
    | 0xED -> b1 >= 0x80 && b1 <= 0x9F
    | 0xF0 -> b1 >= 0x90 && b1 <= 0xBF
    | 0xF4 -> b1 >= 0x80 && b1 <= 0x8F
    | _ -> b1 land 0xC0 = 0x80
  in
  let rec go acc i =
    if i >= n then List.rev (n :: acc)
    else
      let b0 = Char.code s.[i] in
      let width =
        if b0 < 0x80 then 1
        else if b0 land 0xE0 = 0xC0 && b0 >= 0xC2 && cont (i + 1) then 2
        else if b0 land 0xF0 = 0xE0 && second_ok b0 (byte (i + 1)) && cont (i + 2) then 3
        else if
          b0 land 0xF8 = 0xF0
          && b0 <= 0xF4
          && second_ok b0 (byte (i + 1))
          && cont (i + 2)
          && cont (i + 3)
        then 4
        else 1 (* malformed byte *)
      in
      go (i :: acc) (i + width)
  in
  go [] 0

(** [wire_builtins ctx] registers the native implementations for the prelude's builtin marker terms.
    Call after {!load}. Integer semantics per decision D2: OCaml native 63-bit ints; add/sub/mul
    wrap on overflow (mod 2^63); div truncates toward zero and fails with [Arithmetic] on zero. *)
let wire_builtins (ctx : Eval.ctx) : (unit, Diag.t list) result =
  let store = Eval.store ctx in
  let ( let* ) = Result.bind in
  let* true_con = lookup_hash store ~kind:Resolve.KCon "true" in
  let* false_con = lookup_hash store ~kind:Resolve.KCon "false" in
  let vbool b =
    if b then Value.VCon { con = true_con; name = "true"; args = [] }
    else Value.VCon { con = false_con; name = "false"; args = [] }
  in
  let int2 name f args =
    match args with
    | [ Value.VInt a; Value.VInt b ] -> f a b
    | args ->
        Error
          (Runtime_err.Type_error
             (Printf.sprintf "%s expects two ints, got %s" name
                (String.concat ", " (List.map Value.show args))))
  in
  let natives =
    [
      ("add", int2 "add" (fun a b -> Ok (Value.VInt (a + b))));
      ("sub", int2 "sub" (fun a b -> Ok (Value.VInt (a - b))));
      ("mul", int2 "mul" (fun a b -> Ok (Value.VInt (a * b))));
      ( "div",
        int2 "div" (fun a b ->
            if b = 0 then Error (Runtime_err.Arithmetic "division by zero")
            else Ok (Value.VInt (a / b))) );
      ("eq", int2 "eq" (fun a b -> Ok (vbool (a = b))));
      ("lt", int2 "lt" (fun a b -> Ok (vbool (a < b))));
    ]
  in
  let rec go = function
    | [] -> Ok ()
    | (name, native) :: rest ->
        let* h = lookup_hash store ~kind:Resolve.KTerm name in
        Eval.register_builtin ctx h (Value.VTrustedBuiltin (Trusted_builtin.make name native));
        go rest
  in
  let* () = go natives in
  let real2 name f args =
    match args with
    | [ Value.VReal a; Value.VReal b ] -> Ok (Value.VReal (f a b))
    | args ->
        Error
          (Runtime_err.Type_error
             (Printf.sprintf "%s expects two reals, got %s" name
                (String.concat ", " (List.map Value.show args))))
  in
  let optional name native =
    match lookup_hash store ~kind:Resolve.KTerm name with
    | Error _ -> () (* prelude without this layer *)
    | Ok h -> Eval.register_builtin ctx h (Value.VTrustedBuiltin (Trusted_builtin.make name native))
  in
  let optional_internal name native =
    match Store.lookup_internal_kind store name Resolve.KTerm with
    | None -> ()
    | Some { Resolve.hash; _ } ->
        Eval.register_builtin ctx hash (Value.VTrustedBuiltin (Trusted_builtin.make name native))
  in
  optional "mod"
    (int2 "mod" (fun a b ->
         if b = 0 then Error (Runtime_err.Arithmetic "modulo by zero")
         else Ok (Value.VInt (a mod b))));
  let stable_optional public_name intrinsic_id native =
    match lookup_hash store ~kind:Resolve.KTerm public_name with
    | Error _ -> ()
    | Ok h ->
        Eval.register_builtin ctx h
          (Value.VTrustedBuiltin (Trusted_builtin.make intrinsic_id native))
  in
  stable_optional "real.add" "add-real" (real2 "real.add" ( +. ));
  stable_optional "real.mul" "mul-real" (real2 "real.mul" ( *. ));
  stable_optional "real.div" "div-real" (real2 "real.div" ( /. ));
  stable_optional "real.sub" "sub-real" (real2 "real.sub" ( -. ));
  stable_optional "async.scope" "async.scope-v0" (fun _ ->
      Error (Runtime_err.Type_error "async.scope requires the deterministic interpreter scheduler"));
  stable_optional "real.lt?" "lt-real" (fun args ->
      match args with
      | [ Value.VReal a; Value.VReal b ] -> Ok (vbool (a < b))
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "real.lt? expects two reals, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  let real_predicate name predicate args =
    match args with
    | [ Value.VReal a; Value.VReal b ] -> Ok (vbool (predicate a b))
    | args ->
        Error
          (Runtime_err.Type_error
             (Printf.sprintf "%s expects two reals, got %s" name
                (String.concat ", " (List.map Value.show args))))
  in
  optional "real.gt?" (real_predicate "real.gt?" ( > ));
  optional "real.gte?" (real_predicate "real.gte?" ( >= ));
  optional "real.lte?" (real_predicate "real.lte?" ( <= ));
  (* three-way comparison feeding the ord dictionary (stdlib SL.2) *)
  (match
     ( lookup_hash store ~kind:Resolve.KCon "less",
       lookup_hash store ~kind:Resolve.KCon "equal",
       lookup_hash store ~kind:Resolve.KCon "greater" )
   with
  | Ok less_c, Ok equal_c, Ok greater_c ->
      let vord c =
        if c < 0 then Value.VCon { con = less_c; name = "less"; args = [] }
        else if c = 0 then Value.VCon { con = equal_c; name = "equal"; args = [] }
        else Value.VCon { con = greater_c; name = "greater"; args = [] }
      in
      optional "int-compare" (int2 "int-compare" (fun a b -> Ok (vord (compare a b))));
      (* bytewise = codepoint order for UTF-8, documented in stdlib.md (SL.5) *)
      optional "text-compare" (fun args ->
          match args with
          | [ Value.VText a; Value.VText b ] -> Ok (vord (compare a b))
          | args ->
              Error
                (Runtime_err.Type_error
                   (Printf.sprintf "text-compare expects two texts, got %s"
                      (String.concat ", " (List.map Value.show args)))))
  | _ -> ());
  (* SL.5 text builtins below use codepoint semantics per D9 via {!utf8_boundaries}. *)
  let type_err name args =
    Error
      (Runtime_err.Type_error
         (Printf.sprintf "%s got unexpected arguments %s" name
            (String.concat ", " (List.map Value.show args))))
  in
  let text1 name f args = match args with [ Value.VText s ] -> f s | args -> type_err name args in
  let text2 name f args =
    match args with [ Value.VText a; Value.VText b ] -> f a b | args -> type_err name args
  in
  optional "text.length"
    (text1 "text.length" (fun s -> Ok (Value.VInt (List.length (utf8_boundaries s) - 1))));
  optional "text.concat" (text2 "text.concat" (fun a b -> Ok (Value.VText (a ^ b))));
  optional "text.slice" (fun args ->
      match args with
      | [ Value.VText s; Value.VInt a; Value.VInt b ] ->
          (* codepoint-indexed [a, b), clamped to the text's bounds *)
          let bs = Array.of_list (utf8_boundaries s) in
          let len = Array.length bs - 1 in
          let clamp i = max 0 (min len i) in
          let a = clamp a and b = clamp b in
          Ok (Value.VText (if a >= b then "" else String.sub s bs.(a) (bs.(b) - bs.(a))))
      | args -> type_err "text.slice" args);
  optional "text.trim"
    (text1 "text.trim" (fun s ->
         (* ASCII whitespace only in this draft (documented) *)
         let ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
         let n = String.length s in
         let i = ref 0 and j = ref n in
         while !i < n && ws s.[!i] do
           incr i
         done;
         while !j > !i && ws s.[!j - 1] do
           decr j
         done;
         Ok (Value.VText (String.sub s !i (!j - !i)))));
  let substring_at s sub i =
    String.length sub <= String.length s - i && String.sub s i (String.length sub) = sub
  in
  optional "text.contains?"
    (text2 "text.contains?" (fun s sub ->
         let rec go i =
           i <= String.length s - String.length sub && (substring_at s sub i || go (i + 1))
         in
         Ok (vbool (sub = "" || go 0))));
  optional "text.empty?" (text1 "text.empty?" (fun s -> Ok (vbool (s = ""))));
  optional "text.from-int" (fun args ->
      match args with
      | [ Value.VInt i ] -> Ok (Value.VText (string_of_int i))
      | args -> type_err "text.from-int" args);
  (* from-real reuses the printer's spelling so from-real/to-real round-trips bit-exactly *)
  optional "text.from-real" (fun args ->
      match args with
      | [ Value.VReal r ] -> Ok (Value.VText (Printer.real_repr r))
      | args -> type_err "text.from-real" args);
  (match
     (lookup_hash store ~kind:Resolve.KCon "nil", lookup_hash store ~kind:Resolve.KCon "cons")
   with
  | Ok nil_h, Ok cons_h ->
      let vnil = Value.VCon { con = nil_h; name = "nil"; args = [] } in
      let vcons x xs = Value.VCon { con = cons_h; name = "cons"; args = [ x; xs ] } in
      let vlist_of_texts ts = List.fold_right (fun t acc -> vcons (Value.VText t) acc) ts vnil in
      let rec texts_of_vlist = function
        | Value.VCon { name = "nil"; args = []; _ } -> Ok []
        | Value.VCon { name = "cons"; args = [ Value.VText text; rest ]; _ } ->
            Result.map (fun texts -> text :: texts) (texts_of_vlist rest)
        | value ->
            Error
              (Runtime_err.Type_error
                 (Printf.sprintf "text.join expects a list of texts, got %s" (Value.show value)))
      in
      optional "text.split"
        (text2 "text.split" (fun s sep ->
             if sep = "" then
               (* singleton-codepoint texts: consistent with the deliberate absence of Char *)
               let bs = utf8_boundaries s in
               let rec pieces = function
                 | a :: (b :: _ as rest) -> String.sub s a (b - a) :: pieces rest
                 | _ -> []
               in
               Ok (vlist_of_texts (pieces bs))
             else begin
               let out = ref [] and start = ref 0 and i = ref 0 in
               let sn = String.length s and pn = String.length sep in
               while !i <= sn - pn do
                 if String.sub s !i pn = sep then begin
                   out := String.sub s !start (!i - !start) :: !out;
                   start := !i + pn;
                   i := !i + pn
                 end
                 else incr i
               done;
               out := String.sub s !start (sn - !start) :: !out;
               Ok (vlist_of_texts (List.rev !out))
             end));
      stable_optional "text.join-list" "text.join" (fun args ->
          match args with
          | [ texts; Value.VText separator ] ->
              Result.map
                (fun texts -> Value.VText (String.concat separator texts))
                (texts_of_vlist texts)
          | args -> type_err "text.join" args);
      stable_optional "text.join" "text.join-variadic-v1" (fun args ->
          let rec join buffer index = function
            | [] -> Ok (Value.VText (Buffer.contents buffer))
            | Value.VText text :: rest ->
                Buffer.add_string buffer text;
                join buffer (index + 1) rest
            | value :: _ ->
                Error
                  (Runtime_err.Type_error
                     (Printf.sprintf "text.join expects Text at argument %d, got %s" index
                        (Value.show value)))
          in
          join (Buffer.create 32) 1 args)
  | _ -> ());
  optional_internal "governance.fresh-audit-run-id" (fun args ->
      match args with
      | [] -> Ok (Value.VHash (Eval.fresh_audit_run_id ctx))
      | args -> type_err "governance.fresh-audit-run-id" args);
  optional_internal "governance.require-audit-run-id" (fun args ->
      match args with
      | [ Value.VHash token; Value.VHash owner ] when Hash.equal token owner -> Ok (Value.VTuple [])
      | [ Value.VHash _; Value.VHash _ ] ->
          Error
            (Runtime_err.Type_error
               "stale AuditSequence: token does not belong to the active with-sequence owner")
      | args -> type_err "governance.require-audit-run-id" args);
  (match
     (lookup_hash store ~kind:Resolve.KCon "some", lookup_hash store ~kind:Resolve.KCon "none")
   with
  | Ok some_h, Ok none_h ->
      let vsome v = Value.VCon { con = some_h; name = "some"; args = [ v ] } in
      let vnone = Value.VCon { con = none_h; name = "none"; args = [] } in
      (* to-int / to-real accept exactly the reader's number spellings *)
      optional "text.to-int"
        (text1 "text.to-int" (fun s ->
             match Reader.classify_literal s with
             | Some (Form.Int i) -> Ok (vsome (Value.VInt i))
             | _ -> Ok vnone));
      optional "text.to-real"
        (text1 "text.to-real" (fun s ->
             match Reader.classify_literal s with
             | Some (Form.Real r) -> Ok (vsome (Value.VReal r))
             | Some (Form.Int i) -> Ok (vsome (Value.VReal (float_of_int i)))
             | _ -> Ok vnone))
  | _ -> ());
  (* --- W6.6 code reflection: quote payloads built and destructured from Jacquard.
     of-int/of-text wrap scalars as (lit ...) forms; form/un-form build and split
     arbitrary heads; eq? is the metadata-law equality; diff renders the semantic
     differ's smallest disagreeing subtrees. --- *)
  optional "code.of-int" (fun args ->
      match args with
      | [ Value.VInt i ] -> Ok (Value.VCode (Form.form "lit" [ Form.Int i ]))
      | args -> type_err "code.of-int" args);
  optional "code.of-real" (fun args ->
      match args with
      | [ Value.VReal real ] -> Ok (Value.VCode (Form.form "lit" [ Form.Real real ]))
      | args -> type_err "code.of-real" args);
  optional "code.of-text" (fun args ->
      match args with
      | [ Value.VText t ] -> Ok (Value.VCode (Form.form "lit" [ Form.Text t ]))
      | args -> type_err "code.of-text" args);
  optional "code.of-hash" (fun args ->
      match args with
      | [ Value.VHash hash ] -> Ok (Value.VCode (Form.form "hash" [ Form.Hash hash ]))
      | args -> type_err "code.of-hash" args);
  optional "hash.to-text" (fun args ->
      match args with
      | [ Value.VHash hash ] -> Ok (Value.VText (Hash.to_hex hash))
      | args -> type_err "hash.to-text" args);
  (match
     (lookup_hash store ~kind:Resolve.KCon "ok", lookup_hash store ~kind:Resolve.KCon "err")
   with
  | Ok ok_h, Ok err_h ->
      let vok value = Value.VCon { con = ok_h; name = "ok"; args = [ value ] } in
      let verr message = Value.VCon { con = err_h; name = "err"; args = [ Value.VText message ] } in
      optional "hash.parse" (fun args ->
          match args with
          | [ Value.VText spelling ] -> (
              match Hash.of_canonical_hex spelling with
              | Some hash -> Ok (vok (Value.VHash hash))
              | None -> Ok (verr "expected 64 lowercase hexadecimal HASH_V0 digits"))
          | args -> type_err "hash.parse" args);
      optional "governance.resolve-operation-id" (fun args ->
          match args with
          | [ Value.VText qualified ] -> (
              match String.index_opt qualified '.' with
              | None | Some 0 -> Ok (verr "invalid Call: expected a resolved effect.operation name")
              | Some separator when separator = String.length qualified - 1 ->
                  Ok (verr "invalid Call: expected a resolved effect.operation name")
              | Some separator -> (
                  let effect_name = String.sub qualified 0 separator in
                  let operation_name =
                    String.sub qualified (separator + 1) (String.length qualified - separator - 1)
                  in
                  match Store.lookup_kind store effect_name Resolve.KEffect with
                  | None ->
                      Ok
                        (verr
                           (Printf.sprintf
                              "invalid Call: effect `%s` is not resolved in the current store"
                              effect_name))
                  | Some { Resolve.hash = effect_hash; _ } -> (
                      match Store.locate store effect_hash with
                      | Ok
                          {
                            Store.decl_hash;
                            decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ };
                            role = Store.Whole;
                            _;
                          } ->
                          let rec find ordinal = function
                            | [] ->
                                Ok
                                  (verr
                                     (Printf.sprintf
                                        "invalid Call: operation `%s` is not a member of resolved \
                                         effect `%s`"
                                        operation_name effect_name))
                            | ({ Kernel.op_name; _ } : Kernel.opspec) :: _
                              when String.equal op_name operation_name ->
                                Ok (vok (Value.VHash (Canon.op_hash decl_hash ordinal)))
                            | _ :: rest -> find (ordinal + 1) rest
                          in
                          find 0 ops
                      | Ok _ | Error _ ->
                          Ok
                            (verr
                               (Printf.sprintf
                                  "invalid Call: effect `%s` has no exact resolved declaration"
                                  effect_name)))))
          | args -> type_err "governance.resolve-operation-id" args);
      optional "governance.effect-order-key" (fun args ->
          match args with
          | [ Value.VHash identity ] ->
              let hex = Hash.to_hex identity in
              let key =
                match Effect_registry.canonical_order identity with
                | Some position -> Printf.sprintf "0:%08d:%s" position hex
                | None -> "1:" ^ hex
              in
              Ok (Value.VText key)
          | args -> type_err "governance.effect-order-key" args)
  | _ -> ());
  (match
     (lookup_hash store ~kind:Resolve.KCon "some", lookup_hash store ~kind:Resolve.KCon "none")
   with
  | Ok some_h, Ok none_h -> (
      let vsome v = Value.VCon { con = some_h; name = "some"; args = [ v ] } in
      let vnone = Value.VCon { con = none_h; name = "none"; args = [] } in
      optional "code.to-int" (fun args ->
          match args with
          | [ Value.VCode { Form.head = "lit"; args = [ Form.Int i ]; _ } ] ->
              Ok (vsome (Value.VInt i))
          | [ Value.VCode _ ] -> Ok vnone
          | args -> type_err "code.to-int" args);
      optional "code.to-text" (fun args ->
          match args with
          | [ Value.VCode { Form.head = "lit"; args = [ Form.Text t ]; _ } ] ->
              Ok (vsome (Value.VText t))
          | [ Value.VCode _ ] -> Ok vnone
          | args -> type_err "code.to-text" args);
      match
        (lookup_hash store ~kind:Resolve.KCon "nil", lookup_hash store ~kind:Resolve.KCon "cons")
      with
      | Ok nil_h, Ok cons_h ->
          let vnil = Value.VCon { con = nil_h; name = "nil"; args = [] } in
          let vcons x xs = Value.VCon { con = cons_h; name = "cons"; args = [ x; xs ] } in
          let rec codes_of_vlist = function
            | Value.VCon { name = "nil"; args = []; _ } -> Ok []
            | Value.VCon { name = "cons"; args = [ Value.VCode f; rest ]; _ } ->
                Result.map (fun fs -> f :: fs) (codes_of_vlist rest)
            | v ->
                Error
                  (Runtime_err.Type_error
                     (Printf.sprintf "code.form expects a list of code, got %s" (Value.show v)))
          in
          optional "code.form" (fun args ->
              match args with
              | [ Value.VText head; xs ] ->
                  if not (Reader.valid_head head) then
                    Error
                      (Runtime_err.Type_error
                         (Printf.sprintf "code.form: %S is not a valid form head" head))
                  else
                    Result.map
                      (fun fs -> Value.VCode (Form.form head (List.map (fun f -> Form.F f) fs)))
                      (codes_of_vlist xs)
              | args -> type_err "code.form" args);
          optional "code.un-form" (fun args ->
              match args with
              | [ Value.VCode f ] ->
                  let sub_forms =
                    List.filter_map (function Form.F g -> Some g | _ -> None) f.Form.args
                  in
                  (* forms with scalar args (lit payloads) split only when every arg is a
                     form; scalars stay opaque behind to-int/to-text *)
                  if List.length sub_forms = List.length f.Form.args then
                    Ok
                      (vsome
                         (Value.VTuple
                            [
                              Value.VText f.Form.head;
                              List.fold_right
                                (fun g acc -> vcons (Value.VCode g) acc)
                                sub_forms vnil;
                            ]))
                  else Ok vnone
              | args -> type_err "code.un-form" args)
      | _ -> ())
  | _ -> ());
  optional "code.eq?" (fun args ->
      match args with
      | [ Value.VCode a; Value.VCode b ] -> Ok (vbool (Form.equal_ignoring_meta a b))
      | args -> type_err "code.eq?" args);
  optional "code.diff" (fun args ->
      match args with
      | [ Value.VCode a; Value.VCode b ] ->
          let ds = Diff.form_divergences ~path:"log" a b in
          Ok
            (Value.VText
               (if ds = [] then "identical"
                else
                  String.concat "; "
                    (List.map
                       (fun { Diff.path; a; b } -> Printf.sprintf "at %s: - %s + %s" path a b)
                       ds)))
      | args -> type_err "code.diff" args);
  optional "code.render" (fun args ->
      match args with
      | [ Value.VCode form ] -> Ok (Value.VText (Printer.print_compact form))
      | args -> type_err "code.render" args);
  optional "code.hash" (fun args ->
      match args with
      | [ Value.VCode form ] -> Ok (Value.VHash (Hash.of_string (Printer.print_compact form)))
      | args -> type_err "code.hash" args);
  (* pmf : (distribution a, a) -> real and support : distribution a -> list (pair a real)
     (W4.1/W4.4); native implementations over the recognized constructors *)
  optional "debug.inspect" (fun args ->
      match args with
      | [ v ] -> Ok (Value.VText (Value.show v))
      | args -> type_err "debug.inspect" args);
  optional "pmf" (fun args ->
      match args with
      | [ dv; v ] ->
          Result.bind (Infer_dist.dist_of_value ctx dv) (fun d ->
              Result.map (fun p -> Value.VReal p) (Infer_dist.pmf ctx d v))
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "pmf expects a distribution and a value, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  optional "dist.sample-lw" (fun args ->
      match args with
      | [ thunk; Value.VInt samples; Value.VInt seed ] -> (
          if samples <= 0 then
            Error (Runtime_err.Arithmetic "dist.sample-lw needs a positive sample count")
          else
            match
              Infer_dist.likelihood_weighting ctx ~seed ~samples (fun () ->
                  Eval.apply_state ctx thunk [])
            with
            | Error [ diagnostic ] -> Error (Runtime_err.Diagnostic diagnostic)
            | Error diagnostics ->
                (* Inference currently returns exactly one diagnostic. Keep this boundary total if
                   that API later reports several failures, while retaining a structured primary
                   inference identity instead of misclassifying them as arithmetic. *)
                let cause =
                  match diagnostics with
                  | [] -> "the inference driver failed without reporting a cause"
                  | diagnostics -> String.concat "; " (List.map Diag.to_cause_string diagnostics)
                in
                Error
                  (Runtime_err.Diagnostic
                     (Diag.error ~domain:Inference ~code:"E0902"
                        ~summary:"Probabilistic inference stopped on a runtime failure." ~cause
                        ~next_step:"Correct the reported model runtime failure and rerun inference."
                        ~contrast:None ()))
            | Ok p -> (
                match
                  ( Store.lookup_kind store "mk-pair" Resolve.KCon,
                    Store.lookup_kind store "cons" Resolve.KCon,
                    Store.lookup_kind store "nil" Resolve.KCon )
                with
                | ( Some { Resolve.hash = ph; _ },
                    Some { Resolve.hash = ch; _ },
                    Some { Resolve.hash = nh; _ } ) ->
                    Ok
                      (List.fold_right
                         (fun (v, pr) acc ->
                           Value.VCon
                             {
                               con = ch;
                               name = "cons";
                               args =
                                 [
                                   Value.VCon
                                     { con = ph; name = "mk-pair"; args = [ v; Value.VReal pr ] };
                                   acc;
                                 ];
                             })
                         p.Infer_dist.entries
                         (Value.VCon { con = nh; name = "nil"; args = [] }))
                | _ -> Error (Runtime_err.Unresolved "prelude list constructors")))
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "dist.sample-lw expects a thunk and two ints, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  optional "support" (fun args ->
      match args with
      | [ dv ] ->
          Result.bind (Infer_dist.dist_of_value ctx dv) (fun d ->
              Result.bind (Infer_dist.support ctx d) (fun entries ->
                  match
                    ( Store.lookup_kind store "mk-pair" Resolve.KCon,
                      Store.lookup_kind store "cons" Resolve.KCon,
                      Store.lookup_kind store "nil" Resolve.KCon )
                  with
                  | ( Some { Resolve.hash = ph; _ },
                      Some { Resolve.hash = ch; _ },
                      Some { Resolve.hash = nh; _ } ) ->
                      Ok
                        (List.fold_right
                           (fun (x, p) acc ->
                             Value.VCon
                               {
                                 con = ch;
                                 name = "cons";
                                 args =
                                   [
                                     Value.VCon
                                       { con = ph; name = "mk-pair"; args = [ x; Value.VReal p ] };
                                     acc;
                                   ];
                               })
                           entries
                           (Value.VCon { con = nh; name = "nil"; args = [] }))
                  | _ -> Error (Runtime_err.Unresolved "prelude list/pair constructors")))
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "support expects a distribution, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Ok ()

(** [install_console ctx ~out] grants the [console] effect: [print] writes its text through [out]
    and resumes with unit; [read-line] resumes with one line from [read_line] (stdin by default;
    injectable for tests, EOF reads as ""). *)
let install_console ?(read_line = fun () -> try Stdlib.read_line () with End_of_file -> "")
    (ctx : Eval.ctx) ~(out : string -> unit) : (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* print_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "print" in
  let* read_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "read-line" in
  Eval.register_root_handler ctx print_op (fun args ->
      match args with
      | [ Value.VText s ] ->
          out s;
          Ok Value.unit_v
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "print expects one text, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Eval.register_root_handler ctx read_op (fun args ->
      match args with
      | [] -> Ok (Value.VText (read_line ()))
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "read-line expects no arguments, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Ok ()

(** [install_clock ctx] grants [clock]: [now] is milliseconds since the epoch, [sleep] blocks for
    that many milliseconds. Both primitives are injectable for tests. *)
let install_clock ?(now = fun () -> int_of_float (Unix.gettimeofday () *. 1000.))
    ?(sleep = fun ms -> if ms > 0 then Unix.sleepf (float_of_int ms /. 1000.)) (ctx : Eval.ctx) :
    (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* now_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "now" in
  let* sleep_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "sleep" in
  Eval.register_root_handler ctx now_op (fun args ->
      match args with
      | [] -> Ok (Value.VInt (now ()))
      | _ -> Error (Runtime_err.Type_error "now expects no arguments"));
  Eval.register_root_handler ctx sleep_op (fun args ->
      match args with
      | [ Value.VInt ms ] ->
          sleep ms;
          Ok Value.unit_v
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "sleep expects one int, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Ok ()

(** [install_fs ctx] grants [fs]. SANDBOX CAVEAT, stated loudly: the grant is the ONLY boundary —
    [--allow fs] means the whole filesystem, with the process's own privileges. Path-scoped grants
    are future work; until then attenuate with in-language handlers (see fs.read-only in
    prelude/14-world.jqd). IO failures surface as [Runtime_err.Io]. *)
let install_fs (ctx : Eval.ctx) : (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* read_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "read" in
  let* write_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "write" in
  let* lsdir_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "list-dir" in
  let io f = try f () with Sys_error m -> Error (Runtime_err.Io m) in
  Eval.register_root_handler ctx read_op (fun args ->
      match args with
      | [ Value.VText path ] -> io (fun () -> Ok (Value.VText (read_file path)))
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "read expects one path, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Eval.register_root_handler ctx write_op (fun args ->
      match args with
      | [ Value.VText path; Value.VText content ] ->
          io (fun () ->
              let oc = open_out_bin path in
              output_string oc content;
              close_out oc;
              Ok Value.unit_v)
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "write expects a path and a text, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  match
    ( Store.lookup_kind (Eval.store ctx) "nil" Resolve.KCon,
      Store.lookup_kind (Eval.store ctx) "cons" Resolve.KCon )
  with
  | Some { Resolve.hash = nil_h; _ }, Some { Resolve.hash = cons_h; _ } ->
      Eval.register_root_handler ctx lsdir_op (fun args ->
          match args with
          | [ Value.VText path ] ->
              io (fun () ->
                  let entries = Sys.readdir path |> Array.to_list |> List.sort String.compare in
                  Ok
                    (List.fold_right
                       (fun e acc ->
                         Value.VCon { con = cons_h; name = "cons"; args = [ Value.VText e; acc ] })
                       entries
                       (Value.VCon { con = nil_h; name = "nil"; args = [] })))
          | args ->
              Error
                (Runtime_err.Type_error
                   (Printf.sprintf "list-dir expects one path, got %s"
                      (String.concat ", " (List.map Value.show args)))));
      Ok ()
  | _ -> err ~code:"E0702" "prelude list constructors missing for fs.list-dir"

(** [install_infer ?cache_dir ctx] grants [infer] with the STUB completion handler (real API calls
    are out of scope, like real sockets). With [cache_dir], completions are cached content-addressed
    by prompt: each entry is a printed form readable by jacquard fmt, and every call logs
    "infer-cache hit/miss <key>" to stderr — the second identical run is a full hit, which makes
    agent loops deterministic and builds an eval dataset as a side effect. *)
let install_infer ?cache_dir (ctx : Eval.ctx) : (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* complete_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "complete" in
  let stub text model =
    match model with
    | Some m -> Printf.sprintf "<stub completion from %s for: %s>" m text
    | None -> Printf.sprintf "<stub completion for: %s>" text
  in
  let rec mkdir_p dir =
    if dir <> "" && dir <> "." && dir <> "/" && not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      try Sys.mkdir dir 0o755 with Sys_error _ -> ()
    end
  in
  let cached text model k =
    match cache_dir with
    | None -> k ()
    | Some dir -> (
        (* length-prefixed fields: a prompt text containing the separator cannot collide
           across the text/model split, and future prompt fields extend the same scheme
           instead of silently aliasing old keys *)
        let key =
          let m = Option.value model ~default:"" in
          Hash.to_hex
            (Hash.of_string
               (Printf.sprintf "%d:%s%d:%s" (String.length text) text (String.length m) m))
        in
        let path = Filename.concat dir (key ^ ".jqd") in
        let entry_form completion =
          Form.form "infer-cache-entry"
            [
              Form.F
                (Form.form "prompt"
                   (Form.Text text :: (match model with Some m -> [ Form.Text m ] | None -> [])));
              Form.F (Form.form "completion" [ Form.Text completion ]);
            ]
        in
        (* a READABLE entry is a hit; absent or corrupt is a miss that recomputes and
           (re)writes. Cache IO failures fall back to uncached — the completion still
           happens and the CLI exit-code contract survives a bad --infer-cache. *)
        let stored =
          if Sys.file_exists path then
            match Reader.parse_one ~file:path (read_file path) with
            | Ok { Form.args = [ _; Form.F { Form.args = [ Form.Text c ]; _ } ]; _ } -> Some c
            | _ -> None
          else None
        in
        match stored with
        | Some c ->
            Printf.eprintf "infer-cache hit %s\n%!" (String.sub key 0 8);
            c
        | None ->
            Printf.eprintf "infer-cache miss %s\n%!" (String.sub key 0 8);
            let c = k () in
            (try
               mkdir_p dir;
               let oc = open_out_bin path in
               output_string oc (Printer.print (entry_form c) ^ "\n");
               close_out oc
             with Sys_error m -> Printf.eprintf "infer-cache unavailable (%s)\n%!" m);
            c)
  in
  Eval.register_root_handler ctx complete_op (fun args ->
      match args with
      | [ Value.VCon { name = "mk-prompt"; args = [ Value.VText text; model_v ]; _ } ] ->
          let model =
            match model_v with
            | Value.VCon { name = "some"; args = [ Value.VText m ]; _ } -> Some m
            | _ -> None
          in
          Ok (Value.VText (cached text model (fun () -> stub text model)))
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "complete expects one prompt, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Ok ()

(** A provider-facing Secret lookup failure. The variants deliberately carry no provider response,
    exception text, or secret bytes, so translating a backend failure into a runtime diagnostic
    cannot disclose confidential material. *)
type secret_lookup_error =
  | Secret_reference_missing
  | Secret_version_missing
  | Secret_backend_failure

type secret_fixture = {
  secret_name : string;
  secret_version : string option;
  secret_bytes : string;
}
(** One deterministic fixture accepted by {!install_secret_fixed}. [secret_bytes] belongs to the
    trusted test harness and is converted directly to an opaque {!Value.VSecret}. *)

let secret_ref_label ~name ~version =
  match version with None -> name | Some version -> Printf.sprintf "%s@%s" name version

let secret_lookup_runtime_error ~name ~version = function
  | Secret_reference_missing ->
      Runtime_err.Io (Printf.sprintf "secret reference not found: %s" name)
  | Secret_version_missing ->
      Runtime_err.Io
        (Printf.sprintf "secret version not found: %s" (secret_ref_label ~name ~version))
  | Secret_backend_failure ->
      Runtime_err.Io (Printf.sprintf "secret backend failure for reference: %s" name)

(** [install_secret ~read ctx] installs the two Secret root operations for an explicitly supplied
    provider adapter. [read ~name ~version] is the only ingress for secret bytes; [secret.expose] is
    the only standard operation that converts the opaque runtime value back to [Text]. Provider
    failures use {!secret_lookup_error}, whose payload-free variants are rendered without backend
    text or values. Installing this handler is itself the embedding's explicit Secret grant; the CLI
    reaches it only through [--allow secret]. *)
let install_secret ~read (ctx : Eval.ctx) : (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* read_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "secret.read" in
  let* expose_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "secret.expose" in
  let bad operation args =
    Error
      (Runtime_err.Type_error
         (Printf.sprintf "%s received %s" operation (String.concat ", " (List.map Value.show args))))
  in
  Eval.register_root_handler ctx read_op (fun args ->
      match args with
      | [ Value.VCon { name = "secret-ref"; args = [ Value.VText name; version ]; _ } ] -> (
          let version =
            match version with
            | Value.VCon { name = "none"; args = []; _ } -> Some None
            | Value.VCon { name = "some"; args = [ Value.VText value ]; _ } -> Some (Some value)
            | _ -> None
          in
          match version with
          | Some version -> (
              match read ~name ~version with
              | Ok bytes -> Ok (Value.VSecret (Secret.of_string bytes))
              | Error lookup_error ->
                  Error (secret_lookup_runtime_error ~name ~version lookup_error))
          | None -> bad "secret.read" args)
      | args -> bad "secret.read" args);
  Eval.register_root_handler ctx expose_op (fun args ->
      match args with
      | [ Value.VSecret secret ] -> Ok (Value.VText (Secret.expose secret))
      | args -> bad "secret.expose" args);
  Ok ()

(** [install_secret_vault ~read ctx] is the provider-neutral vault boundary. The injected callback
    may be backed by a real client, a scripted adapter, record/replay, or fault injection; no vendor
    or transport is selected here, and its failure channel cannot carry provider text or values. *)
let install_secret_vault ~read ctx = install_secret ~read ctx

(** [install_secret_fixed ctx fixtures] installs a deterministic hermetic Secret handler. Exact
    [(name, version)] lookup uses the first matching fixture; an absent name and an absent version
    produce distinct sanitized failures. The handler performs no IO and emits no logs. *)
let install_secret_fixed (ctx : Eval.ctx) (fixtures : secret_fixture list) =
  let read ~name ~version =
    match
      List.find_opt
        (fun fixture ->
          String.equal fixture.secret_name name
          && Option.equal String.equal fixture.secret_version version)
        fixtures
    with
    | Some fixture -> Ok fixture.secret_bytes
    | None ->
        if List.exists (fun fixture -> String.equal fixture.secret_name name) fixtures then
          Error Secret_version_missing
        else Error Secret_reference_missing
  in
  install_secret ~read ctx

let hex_bytes value =
  let buffer = Buffer.create (String.length value * 2) in
  String.iter (fun byte -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte))) value;
  Buffer.contents buffer

(** [secret_environment_key ~name ~version] returns the collision-free environment key used by the
    canonical live environment handler. Names and versions are byte-encoded rather than normalized:
    [JACQUARD_SECRET_V0_<name-hex>_LATEST] or [JACQUARD_SECRET_V0_<name-hex>_VERSION_<version-hex>].
*)
let secret_environment_key ~name ~version =
  let prefix = "JACQUARD_SECRET_V0_" ^ hex_bytes name in
  match version with
  | None -> prefix ^ "_LATEST"
  | Some version -> prefix ^ "_VERSION_" ^ hex_bytes version

(** [install_secret_environment ?getenv ctx] installs the canonical environment-backed Secret grant.
    [getenv] is injectable for hermetic tests; the default reads the process environment. Missing
    keys become reference/version failures, and values are never included in diagnostics or logs. *)
let install_secret_environment ?(getenv = Sys.getenv_opt) (ctx : Eval.ctx) =
  let read ~name ~version =
    match getenv (secret_environment_key ~name ~version) with
    | Some value -> Ok value
    | None ->
        Error
          (match version with None -> Secret_reference_missing | Some _ -> Secret_version_missing)
  in
  install_secret ~read ctx

(* [builtin_signatures] is defined after the grant installers. Module initialization replaces this
   hook before any client can call [install_eval]. *)
let eval_builtin_signatures = ref (fun (_ : Store.t) -> Ok [])

(** [install_eval ctx] grants the [eval] effect: [eval-code] takes a [VCode] payload, validates,
    resolves, and typechecks it against the store's current names before running it in [ctx].
    Failures at that boundary are [Eval_error] (the M0 dynamic check).

    Authority note (review finding, owner decision pending): eval'd code runs at ROOT authority with
    a fresh continuation — handlers interposed around the [eval-code] call site do NOT attenuate the
    payload's effects; only root grants apply. The hard gate (ungranted effects die) still holds.
    Revisit before the M2/M4 attenuation demos rely on wrapping handlers around eval. *)
let install_eval (ctx : Eval.ctx) : (unit, Diag.t list) result =
  match lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "eval-code" with
  | Error ds -> Error ds
  | Ok eval_op ->
      Eval.register_root_handler ctx eval_op (fun args ->
          match args with
          | [ Value.VCode payload ] -> (
              let diags_msg ds = String.concat "; " (List.map Diag.to_cause_string ds) in
              match Kernel.expr_of_form payload with
              | Error ds -> Error (Runtime_err.Eval_error (diags_msg ds))
              | Ok e -> (
                  match Resolve.resolve_expr (Store.names_view (Eval.store ctx)) e with
                  | Error ds -> Error (Runtime_err.Eval_error (diags_msg ds))
                  | Ok e -> (
                      match Check.make_ctx (Eval.store ctx) with
                      | Error ds -> Error (Runtime_err.Eval_error (diags_msg ds))
                      | Ok cctx -> (
                          (match !eval_builtin_signatures (Eval.store ctx) with
                          | Ok signatures -> Check.register_builtin_signatures cctx signatures
                          | Error _ -> ());
                          match Check.check_top cctx (Kernel.Expr e) with
                          | Error ds -> Error (Runtime_err.Eval_error (diags_msg ds))
                          | Ok _ -> Round_robin.run_expr ctx e))))
          | args ->
              Error
                (Runtime_err.Eval_error
                   (Printf.sprintf "expected one code value, got %s"
                      (String.concat ", " (List.map Value.show args)))));
      Ok ()

(** [install_net ctx] grants the [net] effect with the M0 stub handler: [net-fetch] returns a canned
    response naming the URL (the hostile-demo stand-in; real IO is out of scope). *)
let install_net (ctx : Eval.ctx) : (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* fetch_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "fetch" in
  let* resp_con = lookup_hash (Eval.store ctx) ~kind:Resolve.KCon "mk-response" in
  Eval.register_root_handler ctx fetch_op (fun args ->
      match args with
      | [ Value.VCon { name = "mk-request"; args = [ Value.VText url; _body ]; _ } ] ->
          Ok
            (Value.VCon
               {
                 con = resp_con;
                 name = "mk-response";
                 args =
                   [ Value.VInt 200; Value.VText (Printf.sprintf "<stub response for %s>" url) ];
               })
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "fetch expects one request, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Ok ()

(** [install_dist ctx ~seed] grants the [dist] effect with the seeded SAMPLING handler (stdlib
    SL.7): [sample d] draws one value ancestrally; [observe] reaching the root is a defect (decision
    D7's default) surfaced by the CLI as E0904 — observation only means something under an inference
    driver. *)
let install_dist (ctx : Eval.ctx) ~seed : (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* sample_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "sample" in
  let* observe_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "observe" in
  let rng = Infer_dist.Rng.make seed in
  Eval.register_root_handler ctx sample_op (fun args ->
      match args with
      | [ dv ] -> Result.bind (Infer_dist.dist_of_value ctx dv) (Infer_dist.sample_dist ctx rng)
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "sample expects one distribution, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Eval.register_root_handler ctx observe_op (fun _ -> Error Runtime_err.Observe_at_root);
  Ok ()

(** [install_dry ctx ~audit] (TL.2) grants the WORLD without consequences: reads and the clock
    forward to the real primitives (observation is safe), while fs.write, net.fetch, and
    infer.complete are converted into audit records and answered with stubs — the program runs to
    completion, the trail says what it WOULD have done, and nothing mutates. eval is refused
    separately (it runs at root authority and cannot be dried). *)
let install_dry (ctx : Eval.ctx) ~(audit : string list ref) : (unit, Diag.t list) result =
  let ( let* ) = Result.bind in
  let record line = audit := line :: !audit in
  let* () = install_console ctx ~out:print_string in
  let* () = install_clock ctx in
  let* () = install_fs ctx in
  let* () = install_infer ctx in
  let* () = install_dist ctx ~seed:0 in
  (* seed 0: dry runs are deterministic; sampling mutates nothing *)
  (* now override the mutating/world-reaching ops with recorders *)
  let* write_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "write" in
  Eval.register_root_handler ctx write_op (fun args ->
      match args with
      | [ Value.VText path; Value.VText content ] ->
          record (Printf.sprintf "written %s (%d bytes)" path (String.length content));
          Ok Value.unit_v
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "write expects a path and a text, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  let* fetch_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "fetch" in
  let* resp_con = lookup_hash (Eval.store ctx) ~kind:Resolve.KCon "mk-response" in
  Eval.register_root_handler ctx fetch_op (fun args ->
      match args with
      | [ Value.VCon { name = "mk-request"; args = [ Value.VText url; _ ]; _ } ] ->
          record (Printf.sprintf "fetched %s" url);
          Ok
            (Value.VCon
               {
                 con = resp_con;
                 name = "mk-response";
                 args = [ Value.VInt 200; Value.VText "<dry-run response>" ];
               })
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "fetch expects one request, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  let* complete_op = lookup_hash (Eval.store ctx) ~kind:Resolve.KOp "complete" in
  Eval.register_root_handler ctx complete_op (fun args ->
      match args with
      | [ Value.VCon { name = "mk-prompt"; args = [ Value.VText text; _ ]; _ } ] ->
          record (Printf.sprintf "completed prompt %S" text);
          Ok (Value.VText "<dry-run completion>")
      | args ->
          Error
            (Runtime_err.Type_error
               (Printf.sprintf "complete expects one prompt, got %s"
                  (String.concat ", " (List.map Value.show args)))));
  Ok ()

(** The only effects [grant] can install, i.e. the valid [--allow] values; the E0814 hint consults
    this so it never suggests granting a pure effect. *)
let grantable_names = [ "clock"; "console"; "dist"; "eval"; "fs"; "infer"; "net"; "secret" ]

(** [grant ctx name ~out ~seed] installs the root handler for effect [name] (case-insensitive:
    "Eval" and "eval" both work); [seed] feeds the dist sampling handler only. Returns E0703 for
    effects that exist but are not grantable (e.g. [abort]) and unknown effect names alike; keep the
    dispatch in sync with {!grantable_names}. *)
let grant (ctx : Eval.ctx) name ~infer_cache ~out ~seed : (unit, Diag.t list) result =
  match String.lowercase_ascii name with
  | "console" -> install_console ctx ~out
  | "eval" -> install_eval ctx
  | "net" -> install_net ctx
  | "dist" -> install_dist ctx ~seed
  | "clock" -> install_clock ctx
  | "fs" -> install_fs ctx
  | "infer" -> install_infer ?cache_dir:infer_cache ctx
  | "secret" -> install_secret_environment ctx
  | other -> err ~code:"E0703" "effect `%s` is not grantable" other

(** Builtin type signatures for the checker (W3.2): the marker bodies would type as [code], so the
    checker consults these instead, mirroring how {!wire_builtins} overrides evaluation. Arrows are
    pure (closed empty rows); the checker's open coercion supplies call-site slack. *)
let builtin_signatures (store : Store.t) : ((Hash.t * Types.scheme) list, Diag.t list) result =
  let ( let* ) = Result.bind in
  let* int_h = lookup_hash store ~kind:Resolve.KType "int" in
  let* bool_h = lookup_hash store ~kind:Resolve.KType "bool" in
  let int_ty = Types.TCon (int_h, []) in
  let bool_ty = Types.TCon (bool_h, []) in
  let arrow2 result = Types.TArrow ([ int_ty; int_ty ], Types.empty_row, result) in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | (name, ty) :: rest ->
        let* h = lookup_hash store ~kind:Resolve.KTerm name in
        go ((h, Types.mono ty) :: acc) rest
  in
  let* base =
    go []
      [
        ("add", arrow2 int_ty);
        ("sub", arrow2 int_ty);
        ("mul", arrow2 int_ty);
        ("div", arrow2 int_ty);
        ("eq", arrow2 bool_ty);
        ("lt", arrow2 bool_ty);
      ]
  in
  (* mod rides the optional lane like the reals: stub preludes may omit it *)
  let* base =
    match lookup_hash store ~kind:Resolve.KTerm "mod" with
    | Ok h -> Ok (base @ [ (h, Types.mono (arrow2 int_ty)) ])
    | Error _ -> Ok base
  in
  let* base =
    match
      ( lookup_hash store ~kind:Resolve.KTerm "async.scope",
        Hash.of_hex Concurrency_contract.async_effect_hash,
        Hash.of_hex Concurrency_contract.task_result_type_hash )
    with
    | Ok scope_h, Some async_h, Some task_result_h ->
        let level = 1 in
        let value = Types.new_tvar level in
        let tail = Types.new_rvar level in
        let child_row = Types.{ effects = [ async_h ]; tail } in
        let result_row = Types.{ effects = []; tail } in
        let thunk = Types.TArrow ([], child_row, value) in
        let result = Types.TCon (task_result_h, [ value ]) in
        Ok
          (base
          @ [
              (scope_h, { Types.ty = Types.TArrow ([ thunk ], result_row, result); gen_level = 0 });
            ])
    | Error _, _, _ -> Ok base
    | Ok _, (None | Some _), (None | Some _) ->
        Error
          [
            Diag.error ~domain:Concurrency ~code:"E0908"
              ~summary:"Frozen Async scope identities are invalid"
              ~cause:
                "The prelude's frozen Async declarations do not have their expected identities."
              ~next_step:"Rebuild the complete, version-matched prelude and try again."
              ~contrast:None ();
          ]
  in
  (* int-compare ships with ring 0; its ordering result type lives in 02-data *)
  let* base =
    match
      ( lookup_hash store ~kind:Resolve.KType "ordering",
        lookup_hash store ~kind:Resolve.KTerm "int-compare" )
    with
    | Ok ord_h, Ok ic_h -> Ok (base @ [ (ic_h, Types.mono (arrow2 (Types.TCon (ord_h, [])))) ])
    | _ -> Ok base
  in
  (* W6.6 code reflection signatures *)
  let* base =
    match
      ( lookup_hash store ~kind:Resolve.KType "code",
        lookup_hash store ~kind:Resolve.KType "real",
        lookup_hash store ~kind:Resolve.KType "text",
        lookup_hash store ~kind:Resolve.KType "hash",
        lookup_hash store ~kind:Resolve.KType "option",
        lookup_hash store ~kind:Resolve.KType "result",
        lookup_hash store ~kind:Resolve.KType "list",
        lookup_hash store ~kind:Resolve.KTerm "code.form" )
    with
    | Ok code_h, Ok real_h, Ok text_h, Ok hash_h, Ok opt_h, Ok result_h, Ok list_h, Ok _ ->
        let code = Types.TCon (code_h, []) in
        let text = Types.TCon (text_h, []) in
        let hash = Types.TCon (hash_h, []) in
        let opt t = Types.TCon (opt_h, [ t ]) in
        let result e a = Types.TCon (result_h, [ e; a ]) in
        let tlist t = Types.TCon (list_h, [ t ]) in
        let fn params result = Types.mono (Types.TArrow (params, Types.empty_row, result)) in
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | (name, s) :: rest ->
              let* h = lookup_hash store ~kind:Resolve.KTerm name in
              go ((h, s) :: acc) rest
        in
        let* code_sigs =
          go []
            [
              ("code.of-int", fn [ int_ty ] code);
              ("code.of-real", fn [ Types.TCon (real_h, []) ] code);
              ("code.to-int", fn [ code ] (opt int_ty));
              ("code.of-text", fn [ text ] code);
              ("code.of-hash", fn [ hash ] code);
              ("code.to-text", fn [ code ] (opt text));
              ("code.form", fn [ text; tlist code ] code);
              ("code.un-form", fn [ code ] (opt (Types.TTuple [ text; tlist code ])));
              ("code.eq?", fn [ code; code ] bool_ty);
              ("code.diff", fn [ code; code ] text);
              ("code.render", fn [ code ] text);
              ("code.hash", fn [ code ] hash);
              ("hash.parse", fn [ text ] (result text hash));
              ("hash.to-text", fn [ hash ] text);
            ]
        in
        let governance_sigs =
          let optional_sig name signature =
            match lookup_hash store ~kind:Resolve.KTerm name with
            | Ok hash -> [ (hash, signature) ]
            | Error _ -> []
          in
          let hidden name signature =
            match Store.lookup_internal_kind store name Resolve.KTerm with
            | Some { Resolve.hash; _ } -> [ (hash, signature) ]
            | None -> []
          in
          optional_sig "governance.resolve-operation-id" (fn [ text ] (result text hash))
          @ optional_sig "governance.effect-order-key" (fn [ hash ] text)
          @ hidden "governance.fresh-audit-run-id" (fn [] hash)
          @ hidden "governance.require-audit-run-id" (fn [ hash; hash ] (Types.TTuple []))
        in
        Ok (base @ code_sigs @ governance_sigs)
    | _ -> Ok base
  in
  (* the SL.5 text layer (all-or-nothing: 11-text.jqd declares every marker) *)
  let* base =
    match
      ( lookup_hash store ~kind:Resolve.KType "text",
        lookup_hash store ~kind:Resolve.KType "real",
        lookup_hash store ~kind:Resolve.KType "ordering",
        lookup_hash store ~kind:Resolve.KType "option",
        lookup_hash store ~kind:Resolve.KType "list",
        lookup_hash store ~kind:Resolve.KTerm "text.length" )
    with
    | Ok text_h, Ok real_h, Ok ord_h, Ok opt_h, Ok list_h, Ok _ ->
        let text = Types.TCon (text_h, []) in
        let real = Types.TCon (real_h, []) in
        let opt t = Types.TCon (opt_h, [ t ]) in
        let tlist t = Types.TCon (list_h, [ t ]) in
        let fn params result = Types.mono (Types.TArrow (params, Types.empty_row, result)) in
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | (name, s) :: rest ->
              let* h = lookup_hash store ~kind:Resolve.KTerm name in
              go ((h, s) :: acc) rest
        in
        let* text_sigs =
          go []
            [
              ("text.length", fn [ text ] int_ty);
              ("text.concat", fn [ text; text ] text);
              ("text.join-list", fn [ tlist text; text ] text);
              ("text.join", Types.mono (Types.TVariadicArrow (text, Types.empty_row, text)));
              ("text.split", fn [ text; text ] (tlist text));
              ("text.slice", fn [ text; int_ty; int_ty ] text);
              ("text.trim", fn [ text ] text);
              ("text.contains?", fn [ text; text ] bool_ty);
              ("text.empty?", fn [ text ] bool_ty);
              ("text.from-int", fn [ int_ty ] text);
              ("text.to-int", fn [ text ] (opt int_ty));
              ("text.from-real", fn [ real ] text);
              ("text.to-real", fn [ text ] (opt real));
              ("text-compare", fn [ text; text ] (Types.TCon (ord_h, [])));
            ]
        in
        let* base =
          match lookup_hash store ~kind:Resolve.KTerm "debug.inspect" with
          | Error _ -> Ok (base @ text_sigs)
          | Ok di ->
              let av = Types.new_tvar 1 in
              Ok
                (base @ text_sigs
                @ [
                    (di, { Types.ty = Types.TArrow ([ av ], Types.empty_row, text); gen_level = 0 });
                  ])
        in
        Ok base
    | _ -> Ok base
  in
  (* dist-layer builtins are optional (prelude may not ship them) *)
  match
    ( lookup_hash store ~kind:Resolve.KType "real",
      lookup_hash store ~kind:Resolve.KType "distribution",
      lookup_hash store ~kind:Resolve.KType "list",
      lookup_hash store ~kind:Resolve.KType "pair" )
  with
  | Ok real_h, Ok dist_h, Ok list_h, Ok pair_h -> (
      let real_ty = Types.TCon (real_h, []) in
      let rarrow2 = Types.TArrow ([ real_ty; real_ty ], Types.empty_row, real_ty) in
      let a () = Types.new_tvar 1 in
      let pmf_sig =
        let av = a () in
        {
          Types.ty = Types.TArrow ([ Types.TCon (dist_h, [ av ]); av ], Types.empty_row, real_ty);
          gen_level = 0;
        }
      in
      let support_sig =
        let av = a () in
        {
          Types.ty =
            Types.TArrow
              ( [ Types.TCon (dist_h, [ av ]) ],
                Types.empty_row,
                Types.TCon (list_h, [ Types.TCon (pair_h, [ av; real_ty ]) ]) );
          gen_level = 0;
        }
      in
      (* dist.sample-lw : forall a e. (() ->{dist | e} a, int, int) ->{e} list (pair a real)
         — the thunk's row must NAME dist (the driver discharges it), everything else rides
         the shared row variable *)
      let sample_lw_sig =
        match lookup_hash store ~kind:Resolve.KEffect "dist" with
        | Error _ -> None
        | Ok dist_eff ->
            let av = a () in
            let e = Types.new_rvar 1 in
            Some
              {
                Types.ty =
                  Types.TArrow
                    ( [
                        Types.TArrow ([], { Types.effects = [ dist_eff ]; tail = e }, av);
                        int_ty;
                        int_ty;
                      ],
                      { Types.effects = []; tail = e },
                      Types.TCon (list_h, [ Types.TCon (pair_h, [ av; real_ty ]) ]) );
                gen_level = 0;
              }
      in
      match
        ( lookup_hash store ~kind:Resolve.KTerm "real.add",
          lookup_hash store ~kind:Resolve.KTerm "real.mul",
          lookup_hash store ~kind:Resolve.KTerm "real.div",
          lookup_hash store ~kind:Resolve.KTerm "pmf",
          lookup_hash store ~kind:Resolve.KTerm "support" )
      with
      | Ok ar, Ok mr, Ok dr, Ok pm, Ok su ->
          let lw =
            match (sample_lw_sig, lookup_hash store ~kind:Resolve.KTerm "dist.sample-lw") with
            | Some s, Ok h -> [ (h, s) ]
            | _ -> []
          in
          let extra_real =
            (* subtraction and ordering support W6.9's tolerance comparisons *)
            match
              ( lookup_hash store ~kind:Resolve.KTerm "real.sub",
                lookup_hash store ~kind:Resolve.KTerm "real.lt?",
                lookup_hash store ~kind:Resolve.KTerm "real.gt?",
                lookup_hash store ~kind:Resolve.KTerm "real.gte?",
                lookup_hash store ~kind:Resolve.KTerm "real.lte?" )
            with
            | Ok sr, Ok lr, Ok gr, Ok ger, Ok ler ->
                [
                  (sr, Types.mono rarrow2);
                  (lr, Types.mono (Types.TArrow ([ real_ty; real_ty ], Types.empty_row, bool_ty)));
                  (gr, Types.mono (Types.TArrow ([ real_ty; real_ty ], Types.empty_row, bool_ty)));
                  (ger, Types.mono (Types.TArrow ([ real_ty; real_ty ], Types.empty_row, bool_ty)));
                  (ler, Types.mono (Types.TArrow ([ real_ty; real_ty ], Types.empty_row, bool_ty)));
                ]
            | _ -> []
          in
          Ok
            (base
            @ [
                (ar, Types.mono rarrow2);
                (mr, Types.mono rarrow2);
                (dr, Types.mono rarrow2);
                (pm, pmf_sig);
                (su, support_sig);
              ]
            @ lw @ extra_real)
      | _ -> Ok base)
  | _ -> Ok base

let () = eval_builtin_signatures := builtin_signatures
