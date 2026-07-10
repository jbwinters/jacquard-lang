(** Canonical `.jac` printer.

    The printer consumes validated kernel trees, not {!Surface_ast}; it therefore defines canonical
    surface text independently of how permissive parsing becomes. Unsupported forms use the
    documented [jqd { ... }] inversion escape until their native surface rendering lands. *)

type lookup = Surface_name.kind -> Hash.t -> string option

let default_width = 100

exception Bug_unsupported_surface_form

(** [render_name] is the printer's sole D34 spelling boundary. *)
let render_name = Surface_name.render

let pp_sep sep pp fmt items =
  List.iteri
    (fun i item ->
      if i > 0 then Format.fprintf fmt "%s@ " sep;
      pp fmt item)
    items

let kind_of_refkind = function
  | Kernel.Term -> Surface_name.Term
  | Kernel.Con -> Surface_name.Con
  | Kernel.Op -> Surface_name.Op

let hash_name kind hash = Printf.sprintf "#%s:%s" (Hash.to_hex hash) (Surface_name.kind_tag kind)

let name_for_hash lookup meta kind hash =
  match Meta.name meta with
  | Some name -> render_name kind name
  | None -> (
      match Option.bind lookup (fun find -> find kind hash) with
      | Some name -> render_name kind name
      | None -> hash_name kind hash)

let pp_lit fmt = function
  | Kernel.LInt i -> Format.pp_print_string fmt (string_of_int i)
  | Kernel.LReal r -> Format.pp_print_string fmt (Printer.real_repr r)
  | Kernel.LText s -> Format.fprintf fmt "\"%s\"" (Printer.escape_text s)

let pp_named kind fmt name = Format.pp_print_string fmt (render_name kind name)

let pp_gref lookup kind meta fmt = function
  | Kernel.Named name -> pp_named kind fmt name
  | Kernel.Hashed hash -> Format.pp_print_string fmt (name_for_hash lookup meta kind hash)

let rec pp_pat lookup fmt (pat : Kernel.pat) =
  match pat.it with
  | Kernel.PWild -> Format.pp_print_string fmt "_"
  | Kernel.PVar name -> pp_named Surface_name.Term fmt name
  | Kernel.PLit lit -> pp_lit fmt lit
  | Kernel.PCon (con, args) ->
      pp_gref lookup Surface_name.Con pat.meta fmt con;
      if args <> [] then Format.fprintf fmt "(@[<hov>%a@])" (pp_sep "," (pp_pat lookup)) args
  | Kernel.PTuple items -> (
      match items with
      | [] -> Format.pp_print_string fmt "()"
      | [ item ] -> Format.fprintf fmt "(@[<hov>%a@])" (pp_pat lookup) item
      | _ -> Format.fprintf fmt "(@[<hov>%a@])" (pp_sep "," (pp_pat lookup)) items)
  | Kernel.PAs (name, inner) -> (
      match inner.it with
      | Kernel.PAs _ -> raise Bug_unsupported_surface_form
      | _ ->
          Format.fprintf fmt "@[<hov>%a as %a@]" (pp_pat lookup) inner (pp_named Surface_name.Term)
            name)

and pp_row lookup fmt (row : Kernel.row) =
  Format.fprintf fmt "->{@[<hov>";
  pp_sep "," (pp_gref lookup Surface_name.Effect Meta.empty) fmt row.effects;
  (match row.rvar with
  | None -> ()
  | Some tail ->
      if row.effects = [] then Format.pp_print_string fmt "| " else Format.fprintf fmt "@ |@ ";
      pp_named Surface_name.Rvar fmt tail);
  Format.fprintf fmt "@]}"

and pp_ty lookup fmt (ty : Kernel.ty) =
  match ty.it with
  | Kernel.TRef ref -> pp_gref lookup Surface_name.Type ty.meta fmt ref
  | Kernel.TVar name -> pp_named Surface_name.Tvar fmt name
  | Kernel.TApp (head, args) ->
      Format.fprintf fmt "@[<hov>%a@ %a@]" (pp_ty_atom lookup) head
        (pp_sep "" (pp_ty_atom lookup))
        args
  | Kernel.TArrow (params, row, result) ->
      Format.fprintf fmt "@[<hov 2>(%a) %a@ %a@]"
        (pp_sep "," (pp_ty lookup))
        params (pp_row lookup) row (pp_ty lookup) result
  | Kernel.TTuple items -> (
      match items with
      | [] -> Format.pp_print_string fmt "()"
      | [ item ] -> Format.fprintf fmt "(%a,)" (pp_ty lookup) item
      | _ -> Format.fprintf fmt "(%a)" (pp_sep "," (pp_ty lookup)) items)
  | Kernel.TForall (tvars, rvars, body) ->
      Format.fprintf fmt "@[<hov 2>forall";
      if tvars = [] && rvars = [] then Format.fprintf fmt "@ "
      else begin
        List.iter (fun name -> Format.fprintf fmt "@ %a" (pp_named Surface_name.Tvar) name) tvars;
        if rvars <> [] then begin
          Format.fprintf fmt "@ |";
          List.iter (fun name -> Format.fprintf fmt "@ %a" (pp_named Surface_name.Rvar) name) rvars
        end
      end;
      Format.fprintf fmt ".@ %a@]" (pp_ty lookup) body

and pp_ty_atom lookup fmt ty =
  match ty.Kernel.it with
  | Kernel.TApp _ | Kernel.TArrow _ | Kernel.TForall _ ->
      Format.fprintf fmt "(%a)" (pp_ty lookup) ty
  | _ -> pp_ty lookup fmt ty

let quote_marker_base payload =
  let rec symbols acc (form : Form.t) =
    List.fold_left
      (fun acc -> function
        | Form.Sym name -> name :: acc | Form.F child -> symbols acc child | _ -> acc)
      acc form.args
  in
  let names = symbols [] payload in
  let rec choose base =
    if List.exists (String.starts_with ~prefix:base) names then choose (base ^ "x") else base
  in
  choose "surface-unquote-hole"

let restore_quote_splices splices expr =
  let rec restore (expr : Kernel.expr) =
    let it =
      match expr.it with
      | Kernel.Var marker -> (
          match List.assoc_opt marker splices with
          | Some splice -> Kernel.Unquote splice
          | None -> expr.it)
      | Kernel.Lam (params, body) -> Kernel.Lam (params, restore body)
      | Kernel.App (fn, args) -> Kernel.App (restore fn, List.map restore args)
      | Kernel.Let { isrec; binder; value; body } ->
          Kernel.Let { isrec; binder; value = restore value; body = restore body }
      | Kernel.Match (subject, clauses) ->
          Kernel.Match
            ( restore subject,
              List.map
                (fun clause -> { clause with Kernel.cbody = restore clause.Kernel.cbody })
                clauses )
      | Kernel.Tuple items -> Kernel.Tuple (List.map restore items)
      | Kernel.Handle { body; ret; ops } ->
          Kernel.Handle
            {
              body = restore body;
              ret = { ret with Kernel.rbody = restore ret.Kernel.rbody };
              ops = List.map (fun op -> { op with Kernel.obody = restore op.Kernel.obody }) ops;
            }
      | Kernel.Unquote splice -> Kernel.Unquote (restore splice)
      | Kernel.Ann (subject, ty) -> Kernel.Ann (restore subject, ty)
      | (Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.Quote _) as unchanged -> unchanged
    in
    { expr with Kernel.it }
  in
  restore expr

(** [surface_quote_expr payload] recognizes a quoted kernel expression while preserving live
    [unquote] nodes. Nested quotes are parsed independently when printed. Arbitrary quoted triples
    return [None] and use the documented raw escape. *)
let surface_quote_expr payload =
  let base = quote_marker_base payload in
  let next = ref 0 in
  let splices = ref [] in
  let valid = ref true in
  let rec mask (form : Form.t) =
    if String.equal form.head "unquote" then (
      match form.args with
      | [ Form.F splice_form ] -> (
          match Kernel.expr_of_form splice_form with
          | Error _ ->
              valid := false;
              form
          | Ok splice ->
              let marker = base ^ string_of_int !next in
              incr next;
              splices := (marker, splice) :: !splices;
              Form.form ~meta:form.meta "var" [ Form.Sym marker ])
      | _ ->
          valid := false;
          form)
    else if String.equal form.head "quote" then form
    else
      {
        form with
        Form.args =
          List.map (function Form.F child -> Form.F (mask child) | scalar -> scalar) form.args;
      }
  in
  let masked = mask payload in
  if not !valid then None
  else
    match Kernel.expr_of_form masked with
    | Error _ -> None
    | Ok expr -> Some (restore_quote_splices !splices expr)

let rec pp_expr lookup fmt (expr : Kernel.expr) =
  match expr.it with
  | Kernel.Lit lit -> pp_lit fmt lit
  | Kernel.Var name -> pp_named Surface_name.Term fmt name
  | Kernel.Ref (hash, refkind) ->
      let kind = kind_of_refkind refkind in
      Format.pp_print_string fmt (name_for_hash lookup expr.meta kind hash)
  | Kernel.GroupRef index -> (
      match Meta.name expr.meta with
      | Some name -> pp_named Surface_name.Term fmt name
      | None -> Format.fprintf fmt "#group[%d]" index)
  | Kernel.Lam (params, body) ->
      Format.fprintf fmt "@[<hov 2>fn (%a) ->@ %a@]"
        (pp_sep "," (pp_pat lookup))
        params (pp_expr lookup) body
  | Kernel.App (fn, args) ->
      Format.fprintf fmt "@[<hov 2>%a(@,%a)@]" (pp_expr_atom lookup) fn
        (pp_sep "," (pp_expr lookup))
        args
  | Kernel.Let _ -> pp_block lookup fmt expr
  | Kernel.Tuple items -> (
      match items with
      | [] -> Format.pp_print_string fmt "()"
      | [ item ] -> Format.fprintf fmt "(@[<hov>%a,@])" (pp_expr lookup) item
      | _ -> Format.fprintf fmt "(@[<hov>%a@])" (pp_sep "," (pp_expr lookup)) items)
  | Kernel.Ann (subject, ty) ->
      Format.fprintf fmt "@[<hov 2>(%a :@ %a)@]" (pp_expr lookup) subject (pp_ty lookup) ty
  | Kernel.Match (subject, clauses) -> pp_match lookup fmt subject clauses
  | Kernel.Handle { body; ret; ops } -> pp_handle lookup fmt body ret ops
  | Kernel.Quote payload -> pp_quote lookup fmt payload
  | Kernel.Unquote splice -> Format.fprintf fmt "unquote(%a)" (pp_expr lookup) splice

and pp_expr_atom lookup fmt expr =
  match expr.Kernel.it with
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.App _ | Kernel.Match _
  | Kernel.Tuple _ | Kernel.Let _ | Kernel.Handle _ | Kernel.Quote _ | Kernel.Unquote _
  | Kernel.Ann _ ->
      pp_expr lookup fmt expr
  | Kernel.Lam _ -> Format.fprintf fmt "(%a)" (pp_expr lookup) expr

and pp_block lookup fmt expr =
  let rec collect acc current =
    match current.Kernel.it with
    | Kernel.Let { isrec; binder; value; body } -> collect ((isrec, binder, value) :: acc) body
    | _ -> (List.rev acc, current)
  in
  let lets, result = collect [] expr in
  let pp_item fmt (isrec, binder, value) =
    match (isrec, binder.Kernel.it) with
    | false, Kernel.PWild -> pp_expr lookup fmt value
    | _ ->
        Format.fprintf fmt "@[<hov 2>let%s %a =@ %a@]"
          (if isrec then " rec" else "")
          (pp_pat lookup) binder (pp_expr lookup) value
  in
  Format.fprintf fmt "@[<v 2>{@,%a" (pp_sep "" pp_item) lets;
  if lets <> [] then Format.fprintf fmt "@,";
  Format.fprintf fmt "%a@]@,}" (pp_expr lookup) result

and pp_match lookup fmt subject clauses =
  let pp_clause fmt (clause : Kernel.clause) =
    match clause.cbody.it with
    | Kernel.Let _ ->
        Format.fprintf fmt "@[<v 2>| %a -> {@,%a@]@,}" (pp_pat lookup) clause.cpat
          (pp_sequence_contents lookup) clause.cbody
    | _ ->
        Format.fprintf fmt "@[<hov 2>| %a ->@ %a@]" (pp_pat lookup) clause.cpat (pp_expr lookup)
          clause.cbody
  in
  Format.fprintf fmt "@[<v 2>match %a {@,%a@]@,}" (pp_expr lookup) subject (pp_sep "" pp_clause)
    clauses

and pp_arm_body lookup fmt body =
  match body.Kernel.it with
  | Kernel.Let _ -> pp_block lookup fmt body
  | _ -> pp_expr lookup fmt body

and pp_sequence_contents lookup fmt expr =
  let rec collect acc current =
    match current.Kernel.it with
    | Kernel.Let { isrec; binder; value; body } -> collect ((isrec, binder, value) :: acc) body
    | _ -> (List.rev acc, current)
  in
  let lets, result = collect [] expr in
  let pp_item fmt (isrec, binder, value) =
    match (isrec, binder.Kernel.it) with
    | false, Kernel.PWild -> pp_expr lookup fmt value
    | _ ->
        Format.fprintf fmt "@[<hov 2>let%s %a =@ %a@]"
          (if isrec then " rec" else "")
          (pp_pat lookup) binder (pp_expr lookup) value
  in
  pp_sep "" pp_item fmt lets;
  if lets <> [] then Format.fprintf fmt "@,";
  pp_expr lookup fmt result

and pp_handle lookup fmt body ret ops =
  let pp_resume fmt name =
    if String.equal name "_" then Format.pp_print_string fmt "_"
    else pp_named Surface_name.Term fmt name
  in
  let pp_ret fmt (clause : Kernel.ret) =
    Format.fprintf fmt "@[<hov 2>| return %a ->@ %a@]" (pp_pat lookup) clause.rbinder
      (pp_arm_body lookup) clause.rbody
  in
  let pp_op fmt (clause : Kernel.opclause) =
    Format.fprintf fmt "@[<hov 2>| %a(%a) resume %a ->@ %a@]"
      (pp_gref lookup Surface_name.Op clause.ometa)
      clause.op
      (pp_sep "," (pp_pat lookup))
      clause.params pp_resume clause.resume (pp_arm_body lookup) clause.obody
  in
  Format.fprintf fmt "@[<v 2>handle";
  (if is_atomic body then Format.fprintf fmt " %a {" (pp_expr lookup) body
   else
     match body.Kernel.it with
     | Kernel.Let _ -> Format.fprintf fmt " {@,%a@;<0 -2>} {" (pp_sequence_contents lookup) body
     | _ -> Format.fprintf fmt " {@,%a@;<0 -2>} {" (pp_expr lookup) body);
  Format.fprintf fmt "@,%a" pp_ret ret;
  List.iter (fun clause -> Format.fprintf fmt "@,%a" pp_op clause) ops;
  Format.fprintf fmt "@]@,}"

and is_atomic expr =
  match expr.Kernel.it with
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ -> true
  | Kernel.App (fn, _) -> is_atomic_call_head fn
  | _ -> false

and is_atomic_call_head expr =
  match expr.Kernel.it with
  | Kernel.Var _ | Kernel.Ref _ -> true
  | Kernel.App (fn, _) -> is_atomic_call_head fn
  | _ -> false

and pp_quote lookup fmt payload =
  match surface_quote_expr payload with
  | Some expr -> Format.fprintf fmt "@[<hov 2>quote {@ %a@ }@]" (pp_expr lookup) expr
  | None -> Format.fprintf fmt "quote { jqd { %s } }" (Printer.inline_form payload)

let rec group_refs_expr acc (expr : Kernel.expr) =
  match expr.it with
  | Kernel.GroupRef index -> index :: acc
  | Kernel.Lam (_, body) | Kernel.Unquote body | Kernel.Ann (body, _) -> group_refs_expr acc body
  | Kernel.App (fn, args) -> List.fold_left group_refs_expr (group_refs_expr acc fn) args
  | Kernel.Let { value; body; _ } -> group_refs_expr (group_refs_expr acc value) body
  | Kernel.Match (subject, clauses) ->
      List.fold_left
        (fun acc clause -> group_refs_expr acc clause.Kernel.cbody)
        (group_refs_expr acc subject) clauses
  | Kernel.Tuple items -> List.fold_left group_refs_expr acc items
  | Kernel.Handle { body; ret; ops } ->
      List.fold_left
        (fun acc op -> group_refs_expr acc op.Kernel.obody)
        (group_refs_expr (group_refs_expr acc body) ret.Kernel.rbody)
        ops
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.Quote _ -> acc

let printable_term_group bindings =
  let count = List.length bindings in
  if count <= 1 then true
  else
    let edges =
      Array.of_list
        (List.map
           (fun binding ->
             group_refs_expr [] binding.Kernel.value
             |> List.filter (fun index -> index >= 0 && index < count)
             |> List.sort_uniq Int.compare)
           bindings)
    in
    let reaches start =
      let seen = Array.make count false in
      let rec visit index =
        if not seen.(index) then begin
          seen.(index) <- true;
          List.iter visit edges.(index)
        end
      in
      visit start;
      seen
    in
    Array.for_all (fun seen -> Array.for_all Fun.id seen) (Array.init count reaches)

let pp_binding lookup fmt (binding : Kernel.binding) =
  let pp_definition fmt () =
    match binding.value.it with
    | Kernel.Lam (params, body) ->
        Format.fprintf fmt "@[<hov 2>%a(%a) =@ %a@]" (pp_named Surface_name.Term) binding.bname
          (pp_sep "," (pp_pat lookup))
          params (pp_expr lookup) body
    | _ ->
        Format.fprintf fmt "@[<hov 2>%a =@ %a@]" (pp_named Surface_name.Term) binding.bname
          (pp_expr lookup) binding.value
  in
  match binding.annot with
  | None -> pp_definition fmt ()
  | Some ty ->
      Format.fprintf fmt "@[<v>%a : %a@,%a@]" (pp_named Surface_name.Term) binding.bname
        (pp_ty lookup) ty pp_definition ()

let pp_field lookup fmt (field : Kernel.field) =
  match field.label with
  | None -> pp_ty lookup fmt field.fty
  | Some label ->
      Format.fprintf fmt "%a: %a" (pp_named Surface_name.Term) label (pp_ty lookup) field.fty

let pp_constructor lookup fmt (constructor : Kernel.conspec) =
  Format.fprintf fmt "@[<hov>";
  pp_named Surface_name.Con fmt constructor.con_name;
  if constructor.fields <> [] then
    if List.exists (fun field -> Option.is_some field.Kernel.label) constructor.fields then
      Format.fprintf fmt "(@[<hov>%a@])" (pp_sep "," (pp_field lookup)) constructor.fields
    else
      List.iter
        (fun field -> Format.fprintf fmt "@ %a" (pp_ty_atom lookup) field.Kernel.fty)
        constructor.fields;
  Format.fprintf fmt "@]"

let pp_operation lookup fmt (operation : Kernel.opspec) =
  Format.fprintf fmt "@[<hov 2>%a :@ (%a) ->@ %a@]" (pp_named Surface_name.Op) operation.op_name
    (pp_sep "," (pp_ty lookup))
    operation.op_params (pp_ty lookup) operation.op_result

let pp_decl lookup fmt (decl : Kernel.decl) =
  match decl.it with
  | Kernel.DefTerm bindings ->
      if not (printable_term_group bindings) then raise Bug_unsupported_surface_form;
      Format.fprintf fmt "@[<v>%a@]" (pp_sep "" (pp_binding lookup)) bindings
  | Kernel.DefType { tname; tvars; cons } ->
      Format.fprintf fmt "@[<hov 2>type %a" (pp_named Surface_name.Type) tname;
      List.iter (fun name -> Format.fprintf fmt "@ %a" (pp_named Surface_name.Tvar) name) tvars;
      Format.fprintf fmt "@ =@ @[<hv>";
      List.iteri
        (fun index constructor ->
          if index > 0 then Format.fprintf fmt "@ ";
          Format.fprintf fmt "| %a" (pp_constructor lookup) constructor)
        cons;
      Format.fprintf fmt "@]@]"
  | Kernel.DefEffect { ename; evars; ops } ->
      Format.fprintf fmt "@[<v 2>effect %a" (pp_named Surface_name.Effect) ename;
      List.iter (fun name -> Format.fprintf fmt " %a" (pp_named Surface_name.Tvar) name) evars;
      Format.fprintf fmt " where {@,%a@]@,}" (pp_sep "" (pp_operation lookup)) ops

let raw_top top =
  let form = Kernel.to_form top in
  "jqd { " ^ Printer.inline_form form ^ " }"

let render ~width pp value =
  let buffer = Buffer.create 128 in
  let fmt = Format.formatter_of_buffer buffer in
  Format.pp_set_margin fmt width;
  pp fmt value;
  Format.pp_print_flush fmt ();
  Buffer.contents buffer

let pp_clause_fragment lookup fmt (clause : Kernel.clause) =
  match clause.cbody.it with
  | Kernel.Let _ ->
      Format.fprintf fmt "@[<v 2>| %a -> {@,%a@]@,}" (pp_pat lookup) clause.cpat
        (pp_sequence_contents lookup) clause.cbody
  | _ ->
      Format.fprintf fmt "@[<hov 2>| %a ->@ %a@]" (pp_pat lookup) clause.cpat (pp_expr lookup)
        clause.cbody

let pp_ret_fragment lookup fmt (clause : Kernel.ret) =
  Format.fprintf fmt "@[<hov 2>| return %a ->@ %a@]" (pp_pat lookup) clause.rbinder
    (pp_arm_body lookup) clause.rbody

let pp_op_fragment lookup fmt (clause : Kernel.opclause) =
  let pp_resume fmt name =
    if String.equal name "_" then Format.pp_print_string fmt "_"
    else pp_named Surface_name.Term fmt name
  in
  Format.fprintf fmt "@[<hov 2>| %a(%a) resume %a ->@ %a@]"
    (pp_gref lookup Surface_name.Op clause.ometa)
    clause.op
    (pp_sep "," (pp_pat lookup))
    clause.params pp_resume clause.resume (pp_arm_body lookup) clause.obody

let fragment_error form =
  Error
    [
      Diag.error ~code:"E1203"
        (Printf.sprintf "`%s` is not a self-contained surface fragment" form.Form.head);
    ]

(** [print_fragment] renders a kernel form even when it is an interior pattern, type, row, or
    auxiliary product. It is intended for semantic diff and diagnostics; context-ambiguous [group]
    forms return E1203 rather than guessing. *)
let print_fragment ?(lookup : lookup option) ?(width = default_width) (form : Form.t) :
    (string, Diag.t list) result =
  let rendered pp value = Ok (render ~width pp value) in
  let dummy_lit = Form.form "lit" [ Form.Int 0 ] in
  let dummy_pat = Form.form "pwild" [] in
  let dummy_ret = Form.form "ret" [ Form.F dummy_pat; Form.F dummy_lit ] in
  match Kernel.of_form form with
  | Ok (Kernel.Expr expr) -> rendered (pp_expr lookup) expr
  | Ok (Kernel.Decl decl) -> rendered (pp_decl lookup) decl
  | Error _ -> (
      match Kernel.pat_of_form form with
      | Ok pat -> rendered (pp_pat lookup) pat
      | Error _ -> (
          match Kernel.ty_of_form form with
          | Ok ty -> rendered (pp_ty lookup) ty
          | Error _ -> (
              match Kernel.row_of_form form with
              | Ok row -> rendered (pp_row lookup) row
              | Error _ -> (
                  match form.head with
                  | "clause" -> (
                      let wrapper = Form.form "match" [ Form.F dummy_lit; Form.F form ] in
                      match Kernel.expr_of_form wrapper with
                      | Ok { Kernel.it = Kernel.Match (_, [ clause ]); _ } ->
                          rendered (pp_clause_fragment lookup) clause
                      | _ -> fragment_error form)
                  | "ret" -> (
                      let wrapper = Form.form "handle" [ Form.F dummy_lit; Form.F form ] in
                      match Kernel.expr_of_form wrapper with
                      | Ok { Kernel.it = Kernel.Handle { ret; _ }; _ } ->
                          rendered (pp_ret_fragment lookup) ret
                      | _ -> fragment_error form)
                  | "opclause" -> (
                      let wrapper =
                        Form.form "handle" [ Form.F dummy_lit; Form.F dummy_ret; Form.F form ]
                      in
                      match Kernel.expr_of_form wrapper with
                      | Ok { Kernel.it = Kernel.Handle { ops = [ op ]; _ }; _ } ->
                          rendered (pp_op_fragment lookup) op
                      | _ -> fragment_error form)
                  | "binding" -> (
                      let group = Form.form "group" [ Form.F form ] in
                      let wrapper = Form.form "defterm" [ Form.F group ] in
                      match Kernel.decl_of_form wrapper with
                      | Ok { Kernel.it = Kernel.DefTerm [ binding ]; _ } ->
                          rendered (pp_binding lookup) binding
                      | _ -> fragment_error form)
                  | "con" -> (
                      let vars = Form.form "group" [] in
                      let wrapper =
                        Form.form "deftype" [ Form.Sym "fragment"; Form.F vars; Form.F form ]
                      in
                      match Kernel.decl_of_form wrapper with
                      | Ok { Kernel.it = Kernel.DefType { cons = [ constructor ]; _ }; _ } ->
                          rendered (pp_constructor lookup) constructor
                      | _ -> fragment_error form)
                  | "field" -> (
                      let vars = Form.form "group" [] in
                      let constructor = Form.form "con" [ Form.Sym "fragment"; Form.F form ] in
                      let wrapper =
                        Form.form "deftype" [ Form.Sym "fragment"; Form.F vars; Form.F constructor ]
                      in
                      match Kernel.decl_of_form wrapper with
                      | Ok
                          {
                            Kernel.it =
                              Kernel.DefType { cons = [ { Kernel.fields = [ field ]; _ } ]; _ };
                            _;
                          } ->
                          rendered (pp_field lookup) field
                      | _ -> fragment_error form)
                  | "op" -> (
                      let vars = Form.form "group" [] in
                      let wrapper =
                        Form.form "defeffect" [ Form.Sym "fragment"; Form.F vars; Form.F form ]
                      in
                      match Kernel.decl_of_form wrapper with
                      | Ok { Kernel.it = Kernel.DefEffect { ops = [ operation ]; _ }; _ } ->
                          rendered (pp_operation lookup) operation
                      | _ -> fragment_error form)
                  | "eref" -> (
                      let wrapper = Form.form "row" [ Form.F form ] in
                      match Kernel.row_of_form wrapper with
                      | Ok ({ effects = [ effect_ref ]; wmeta; _ } : Kernel.row) ->
                          rendered (pp_gref lookup Surface_name.Effect wmeta) effect_ref
                      | _ -> fragment_error form)
                  | "rvar" -> (
                      match form.args with
                      | [ Form.Sym name ] -> rendered (pp_named Surface_name.Rvar) name
                      | _ -> fragment_error form)
                  | _ -> fragment_error form))))

let is_surface_generated_decl (decl : Kernel.decl) =
  Option.is_some (Meta.surface_generated decl.meta)
  ||
  match decl.it with
  | Kernel.DefTerm bindings ->
      bindings <> []
      && List.for_all
           (fun binding -> Option.is_some (Meta.surface_generated binding.Kernel.bmeta))
           bindings
  | Kernel.DefType _ | Kernel.DefEffect _ -> false

(** [print_top ?lookup ?width top] renders one validated kernel top-level item without a trailing
    newline. [lookup] supplies display names for hash references whose metadata lacks one. A
    [surface-generated] declaration renders as the empty string because its owning surface
    declaration regenerates it. *)
let print_top ?(lookup : lookup option) ?(width = default_width) (top : Kernel.top) :
    (string, Diag.t list) result =
  match top with
  | Kernel.Decl decl when is_surface_generated_decl decl -> Ok ""
  | _ -> (
      match
        match top with
        | Kernel.Expr expr -> render ~width (pp_expr lookup) expr
        | Kernel.Decl decl -> render ~width (pp_decl lookup) decl
      with
      | text -> Ok text
      | exception Bug_unsupported_surface_form -> Ok (raw_top top))

(** [print_file] renders a complete canonical surface file with one trailing newline. *)
let print_file ?(lookup : lookup option) ?(width = default_width) (tops : Kernel.top list) :
    (string, Diag.t list) result =
  let rec loop acc = function
    | [] ->
        let body = String.concat "\n\n" (List.rev acc) in
        Ok (if String.equal body "" then "" else body ^ "\n")
    | top :: rest -> (
        match print_top ?lookup ~width top with
        | Ok "" -> loop acc rest
        | Ok text -> loop (text :: acc) rest
        | Error ds -> Error ds)
  in
  loop [] tops
