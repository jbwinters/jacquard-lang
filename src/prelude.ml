(** Prelude v1 (plan W2.6): the library the kernel keeps out of the language.

    [load] reads every `.wft` file in a prelude directory (sorted by file name), runs each
    declaration through validate-resolve-put against the store's evolving name index, and returns
    the per-file hashes (golden-pinned by tests). [wire_builtins] registers the native
    implementations of the builtin marker terms (see prelude/04-builtins.wft) under their store
    hashes; comparison builtins return the prelude's own [bool] constructors.

    Root handlers are the capability grants (spec §7: no ambient handlers): [install_console] grants
    the [console] effect (its [print] op writes through [out] and resumes with unit); [install_eval]
    grants the [eval] effect (its [eval-code] op validates, resolves, and evaluates a [VCode]
    payload at the boundary — the dynamic check the spec pins for M0). [grant] maps a
    case-insensitive effect name from the CLI to the matching installer. Pure effects (abort etc.)
    deliberately has no root handler: an unhandled [abort] is supposed to die. *)

let err ~code fmt = Printf.ksprintf (fun msg -> Error [ Diag.error ~code msg ]) fmt

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
      |> List.filter (fun f -> Filename.check_suffix f ".wft")
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
      | [] -> Ok (List.rev acc)
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

(** [wire_builtins ctx] registers the native implementations for the prelude's builtin marker terms.
    Call after {!load}. Integer semantics per decision D2: OCaml native 63-bit ints; add/sub/mul
    wrap on overflow (mod 2^63); div truncates toward zero and fails with [Arithmetic] on zero. *)
let wire_builtins (ctx : Eval.ctx) : (unit, Diag.t list) result =
  let store = ctx.Eval.store in
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
        Hashtbl.replace ctx.Eval.builtins h (Value.VBuiltin (name, native));
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
    | Ok h -> Hashtbl.replace ctx.Eval.builtins h (Value.VBuiltin (name, native))
  in
  optional "add-real" (real2 "add-real" ( +. ));
  optional "mul-real" (real2 "mul-real" ( *. ));
  optional "div-real" (real2 "div-real" ( /. ));
  (* three-way comparison feeding the ord dictionary (stdlib SL.2) *)
  (match
     ( lookup_hash store ~kind:Resolve.KCon "less",
       lookup_hash store ~kind:Resolve.KCon "equal",
       lookup_hash store ~kind:Resolve.KCon "greater" )
   with
  | Ok less_c, Ok equal_c, Ok greater_c ->
      let vord con name = Value.VCon { con; name; args = [] } in
      optional "int-compare"
        (int2 "int-compare" (fun a b ->
             Ok
               (if a < b then vord less_c "less"
                else if a = b then vord equal_c "equal"
                else vord greater_c "greater")))
  | _ -> ());
  (* pmf : (distribution a, a) -> real and support : distribution a -> list (pair a real)
     (W4.1/W4.4); native implementations over the recognized constructors *)
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
    and resumes with unit. *)
let install_console (ctx : Eval.ctx) ~(out : string -> unit) : (unit, Diag.t list) result =
  match lookup_hash ctx.Eval.store ~kind:Resolve.KOp "print" with
  | Error ds -> Error ds
  | Ok print_op ->
      Hashtbl.replace ctx.Eval.root_handlers print_op (fun args ->
          match args with
          | [ Value.VText s ] ->
              out s;
              Ok Value.unit_v
          | args ->
              Error
                (Runtime_err.Type_error
                   (Printf.sprintf "print expects one text, got %s"
                      (String.concat ", " (List.map Value.show args)))));
      Ok ()

(** [install_eval ctx] grants the [eval] effect: [eval-code] takes a [VCode] payload, validates it
    as an expression, resolves it against the store's current names, and runs it in [ctx]. Failures
    at that boundary are [Eval_error] (the M0 dynamic check).

    Authority note (review finding, owner decision pending): eval'd code runs at ROOT authority with
    a fresh continuation — handlers interposed around the [eval-code] call site do NOT attenuate the
    payload's effects; only root grants apply. The hard gate (ungranted effects die) still holds.
    Revisit before the M2/M4 attenuation demos rely on wrapping handlers around eval. *)
let install_eval (ctx : Eval.ctx) : (unit, Diag.t list) result =
  match lookup_hash ctx.Eval.store ~kind:Resolve.KOp "eval-code" with
  | Error ds -> Error ds
  | Ok eval_op ->
      Hashtbl.replace ctx.Eval.root_handlers eval_op (fun args ->
          match args with
          | [ Value.VCode payload ] -> (
              let diags_msg ds = String.concat "; " (List.map Diag.to_string ds) in
              match Kernel.expr_of_form payload with
              | Error ds -> Error (Runtime_err.Eval_error (diags_msg ds))
              | Ok e -> (
                  match Resolve.resolve_expr (Store.names_view ctx.Eval.store) e with
                  | Error ds -> Error (Runtime_err.Eval_error (diags_msg ds))
                  | Ok e -> Eval.run_expr ctx e))
          | args ->
              Error
                (Runtime_err.Eval_error
                   (Printf.sprintf "expected one code value, got %s"
                      (String.concat ", " (List.map Value.show args)))));
      Ok ()

(** [install_net ctx] grants the [net] effect with the M0 stub handler: [net-fetch] returns a canned
    response naming the URL (the hostile-demo stand-in; real IO is out of scope). *)
let install_net (ctx : Eval.ctx) : (unit, Diag.t list) result =
  match lookup_hash ctx.Eval.store ~kind:Resolve.KOp "net-fetch" with
  | Error ds -> Error ds
  | Ok fetch_op ->
      Hashtbl.replace ctx.Eval.root_handlers fetch_op (fun args ->
          match args with
          | [ Value.VText url ] -> Ok (Value.VText (Printf.sprintf "<stub response for %s>" url))
          | args ->
              Error
                (Runtime_err.Type_error
                   (Printf.sprintf "net-fetch expects one text, got %s"
                      (String.concat ", " (List.map Value.show args)))));
      Ok ()

(** The only effects [grant] can install, i.e. the valid [--allow] values; the E0814 hint consults
    this so it never suggests granting a pure effect. *)
let grantable_names = [ "console"; "eval"; "net" ]

(** [grant ctx name ~out] installs the root handler for effect [name] (case-insensitive: "Eval" and
    "eval" both work). Returns E0703 for effects that exist but are not grantable (e.g. [abort]) and
    unknown effect names alike; keep the dispatch in sync with {!grantable_names}. *)
let grant (ctx : Eval.ctx) name ~out : (unit, Diag.t list) result =
  match String.lowercase_ascii name with
  | "console" -> install_console ctx ~out
  | "eval" -> install_eval ctx
  | "net" -> install_net ctx
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
  (* int-compare ships with ring 0; its ordering result type lives in 02-data *)
  let* base =
    match
      ( lookup_hash store ~kind:Resolve.KType "ordering",
        lookup_hash store ~kind:Resolve.KTerm "int-compare" )
    with
    | Ok ord_h, Ok ic_h -> Ok (base @ [ (ic_h, Types.mono (arrow2 (Types.TCon (ord_h, [])))) ])
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
      match
        ( lookup_hash store ~kind:Resolve.KTerm "add-real",
          lookup_hash store ~kind:Resolve.KTerm "mul-real",
          lookup_hash store ~kind:Resolve.KTerm "div-real",
          lookup_hash store ~kind:Resolve.KTerm "pmf",
          lookup_hash store ~kind:Resolve.KTerm "support" )
      with
      | Ok ar, Ok mr, Ok dr, Ok pm, Ok su ->
          Ok
            (base
            @ [
                (ar, Types.mono rarrow2);
                (mr, Types.mono rarrow2);
                (dr, Types.mono rarrow2);
                (pm, pmf_sig);
                (su, support_sig);
              ])
      | _ -> Ok base)
  | _ -> Ok base
