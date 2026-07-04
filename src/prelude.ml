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
    case-insensitive effect name from the CLI to the matching installer. The [failure] effect
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
  match Store.lookup_name store name with
  | Some { Resolve.hash; kind = k } when k = kind -> Ok hash
  | Some _ -> err ~code:"E0702" "prelude name `%s` has an unexpected kind" name
  | None -> err ~code:"E0702" "prelude name `%s` is not in the store" name

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
  go natives

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

(** [grant ctx name ~out] installs the root handler for effect [name] (case-insensitive: "Eval" and
    "eval" both work). Returns E0703 for effects that exist but are not grantable (e.g. [failure])
    and unknown effect names alike. *)
let grant (ctx : Eval.ctx) name ~out : (unit, Diag.t list) result =
  match String.lowercase_ascii name with
  | "console" -> install_console ctx ~out
  | "eval" -> install_eval ctx
  | other -> err ~code:"E0703" "effect `%s` is not grantable" other
