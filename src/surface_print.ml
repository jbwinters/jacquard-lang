(** Canonical `.jac` printer.

    The printer consumes validated kernel trees, not {!Surface_ast}; it therefore defines canonical
    surface text independently of how permissive parsing becomes. Unsupported forms use the
    documented [jqd { ... }] inversion escape until their native surface rendering lands. *)

type lookup = Surface_name.kind -> Hash.t -> string option

let default_width = 100

exception Bug_unsupported_surface_form

type context = { trivia : bool }

let canonical_context = { trivia = false }
let trivia_context = { trivia = true }

let leading_comments meta =
  let trivia = Meta.comment_texts Meta.key_trivia meta in
  let docs =
    Meta.docs meta
    |> List.filter_map (function
      | Meta.Doc text | Meta.Comment text -> Some text
      | Meta.Layout _ -> None)
    |> List.filter (fun text -> not (List.mem text trivia))
  in
  trivia @ docs

let meta_has_comments meta =
  leading_comments meta <> []
  || Meta.comment_texts Meta.key_trivia_trailing meta <> []
  || Meta.comment_texts Meta.key_trivia_inner meta <> []

let pp_comments fmt comments =
  List.iter
    (fun comment ->
      Format.pp_print_string fmt comment;
      Format.pp_print_break fmt 1000 0)
    comments

let pp_leading context meta fmt = if context.trivia then pp_comments fmt (leading_comments meta)

let pp_trailing context meta fmt =
  if context.trivia then
    List.iter
      (fun comment -> Format.fprintf fmt " %s" comment)
      (Meta.comment_texts Meta.key_trivia_trailing meta)

let pp_inner context meta fmt =
  if context.trivia then begin
    List.iter
      (fun comment ->
        Format.pp_print_break fmt 1000 0;
        Format.pp_print_string fmt comment)
      (Meta.comment_texts Meta.key_trivia_inner meta);
    if Meta.comment_texts Meta.key_trivia_inner meta <> [] then Format.pp_print_break fmt 1000 0
  end

let pp_eof context meta fmt =
  if context.trivia then pp_comments fmt (Meta.comment_texts Meta.key_trivia_eof meta)

let rec has_comments (form : Form.t) =
  List.exists
    (fun key -> Meta.comment_texts key form.meta <> [])
    [ Meta.key_trivia; Meta.key_trivia_trailing; Meta.key_trivia_inner; Meta.key_trivia_eof ]
  || Meta.docs form.meta <> []
  || List.exists (function Form.F child -> has_comments child | _ -> false) form.args

let drop_final_newline text =
  if String.ends_with ~suffix:"\n" text then String.sub text 0 (String.length text - 1) else text

let indent_lines spaces text =
  let prefix = String.make spaces ' ' in
  String.split_on_char '\n' text |> List.map (fun line -> prefix ^ line) |> String.concat "\n"

let jqd_block context form =
  if context.trivia && has_comments form then
    "jqd {\n" ^ indent_lines 2 (drop_final_newline (Printer.format_all [ form ])) ^ "\n}"
  else "jqd { " ^ Printer.inline_form form ^ " }"

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

let name_for_value_hash lookup meta kind hash =
  match kind with
  | Surface_name.Op -> (
      match Meta.name meta with
      | Some name -> Surface_name.escape Surface_name.Op name
      | None -> (
          match Option.bind lookup (fun find -> find kind hash) with
          | Some name -> Surface_name.escape Surface_name.Op name
          | None -> hash_name kind hash))
  | _ -> name_for_hash lookup meta kind hash

let pp_lit fmt = function
  | Kernel.LInt i -> Format.pp_print_string fmt (string_of_int i)
  | Kernel.LReal r -> Format.pp_print_string fmt (Printer.real_repr r)
  | Kernel.LText s -> Format.fprintf fmt "\"%s\"" (Printer.escape_text s)

let pp_named kind fmt name = Format.pp_print_string fmt (render_name kind name)

let pp_value_name kind fmt name =
  match kind with
  | Surface_name.Op -> Format.pp_print_string fmt (Surface_name.escape Surface_name.Op name)
  | _ -> pp_named kind fmt name

let surface_value_kind meta =
  match Meta.surface_ref_kind meta with
  | Some "con" -> Surface_name.Con
  | Some "op" -> Surface_name.Op
  | Some "term" | Some _ | None -> Surface_name.Term

let pp_gref lookup kind meta fmt = function
  | Kernel.Named name -> pp_named kind fmt name
  | Kernel.Hashed hash -> Format.pp_print_string fmt (name_for_hash lookup meta kind hash)

let rec pp_pat context lookup fmt (pat : Kernel.pat) =
  pp_leading context pat.meta fmt;
  (match pat.it with
  | Kernel.PWild -> Format.pp_print_string fmt "_"
  | Kernel.PVar name -> pp_named Surface_name.Term fmt name
  | Kernel.PLit lit -> pp_lit fmt lit
  | Kernel.PCon (con, args) ->
      pp_gref lookup Surface_name.Con pat.meta fmt con;
      if args <> [] then begin
        Format.fprintf fmt "(@[<hov>%a" (pp_sep "," (pp_pat context lookup)) args;
        pp_inner context pat.meta fmt;
        Format.fprintf fmt "@])"
      end
  | Kernel.PTuple items -> (
      match items with
      | [] -> Format.pp_print_string fmt "()"
      | [ item ] ->
          Format.fprintf fmt "(@[<hov>%a" (pp_pat context lookup) item;
          pp_inner context pat.meta fmt;
          Format.fprintf fmt "@])"
      | _ ->
          Format.fprintf fmt "(@[<hov>%a" (pp_sep "," (pp_pat context lookup)) items;
          pp_inner context pat.meta fmt;
          Format.fprintf fmt "@])")
  | Kernel.PAs (name, inner) -> (
      match inner.it with
      | Kernel.PAs _ -> raise Bug_unsupported_surface_form
      | _ ->
          Format.fprintf fmt "@[<hov>%a as %a@]" (pp_pat context lookup) inner
            (pp_named Surface_name.Term) name));
  pp_trailing context pat.meta fmt

and pp_row context lookup fmt (row : Kernel.row) =
  Format.fprintf fmt "->{@[<hov>";
  pp_leading context row.wmeta fmt;
  pp_sep "," (pp_gref lookup Surface_name.Effect Meta.empty) fmt row.effects;
  (match row.rvar with
  | None -> ()
  | Some tail ->
      if row.effects = [] then Format.pp_print_string fmt "| " else Format.fprintf fmt "@ |@ ";
      pp_named Surface_name.Rvar fmt tail);
  pp_inner context row.wmeta fmt;
  Format.fprintf fmt "@]}";
  pp_trailing context row.wmeta fmt

and pp_ty context lookup fmt (ty : Kernel.ty) =
  pp_leading context ty.meta fmt;
  (match ty.it with
  | Kernel.TRef ref -> pp_gref lookup Surface_name.Type ty.meta fmt ref
  | Kernel.TVar name -> pp_named Surface_name.Tvar fmt name
  | Kernel.TApp (head, args) ->
      Format.fprintf fmt "@[<hov>%a@ %a@]" (pp_ty_atom context lookup) head
        (pp_sep "" (pp_ty_atom context lookup))
        args
  | Kernel.TArrow (params, row, result) ->
      let params_meta = Meta.surface_container "params" ty.meta in
      Format.fprintf fmt "@[<hov 2>";
      pp_leading context params_meta fmt;
      Format.fprintf fmt "(%a" (pp_sep "," (pp_ty context lookup)) params;
      pp_inner context params_meta fmt;
      Format.fprintf fmt ")";
      pp_trailing context params_meta fmt;
      Format.fprintf fmt " %a@ %a@]" (pp_row context lookup) row (pp_ty context lookup) result
  | Kernel.TTuple items -> (
      match items with
      | [] ->
          Format.pp_print_char fmt '(';
          pp_inner context ty.meta fmt;
          Format.pp_print_char fmt ')'
      | [ item ] ->
          Format.fprintf fmt "(@[<hov>%a," (pp_ty context lookup) item;
          pp_inner context ty.meta fmt;
          Format.fprintf fmt "@])"
      | _ ->
          Format.fprintf fmt "(@[<hov>%a" (pp_sep "," (pp_ty context lookup)) items;
          pp_inner context ty.meta fmt;
          Format.fprintf fmt "@])")
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
      Format.fprintf fmt ".@ %a@]" (pp_ty context lookup) body);
  pp_trailing context ty.meta fmt

and pp_ty_atom context lookup fmt ty =
  match ty.Kernel.it with
  | Kernel.TApp _ | Kernel.TArrow _ | Kernel.TForall _ ->
      Format.fprintf fmt "(%a)" (pp_ty context lookup) ty
  | _ -> pp_ty context lookup fmt ty

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

let rec pp_expr context lookup fmt (expr : Kernel.expr) =
  let block_meta = Meta.surface_container "block" expr.meta in
  let paren_meta = Meta.surface_container "paren" expr.meta in
  if context.trivia && (not (Meta.is_empty paren_meta)) && meta_has_comments paren_meta then
    pp_grouped context lookup paren_meta fmt expr
  else if context.trivia && (not (Meta.is_empty block_meta)) && meta_has_comments block_meta then
    match expr.it with
    | Kernel.Let _ -> pp_block context lookup fmt expr
    | _ -> pp_singleton_block context lookup block_meta fmt expr
  else begin
    (match expr.it with Kernel.Let _ -> () | _ -> pp_leading context expr.meta fmt);
    (match (Meta.surface_form expr.meta, expr.it) with
    | Some "if", Kernel.Match (condition, clauses) -> (
        match if_branches clauses with
        | Some (yes, no) -> pp_if context lookup fmt condition yes no
        | None -> pp_match context lookup expr.meta fmt condition clauses)
    | Some "list", (Kernel.Var _ | Kernel.Ref _) -> pp_list context lookup expr.meta fmt []
    | Some _, (Kernel.Var _ | Kernel.Ref _) when Meta.surface_generated expr.meta = Some "list" ->
        pp_list context lookup expr.meta fmt []
    | Some "list", Kernel.App _ -> (
        match list_items expr with
        | Some items -> pp_list context lookup expr.meta fmt items
        | None -> pp_kernel_expr context lookup fmt expr)
    | Some "pipe", Kernel.App (fn, left :: args) ->
        pp_pipe context lookup expr.meta fmt left fn args
    | Some _, _ | None, _ -> pp_kernel_expr context lookup fmt expr);
    match expr.it with Kernel.Let _ -> () | _ -> pp_trailing context expr.meta fmt
  end

and pp_kernel_expr context lookup fmt (expr : Kernel.expr) =
  match expr.it with
  | Kernel.Lit lit -> pp_lit fmt lit
  | Kernel.Var name -> pp_value_name (surface_value_kind expr.meta) fmt name
  | Kernel.Ref (hash, refkind) ->
      let kind = kind_of_refkind refkind in
      Format.pp_print_string fmt (name_for_value_hash lookup expr.meta kind hash)
  | Kernel.GroupRef index -> (
      match Meta.name expr.meta with
      | Some name -> pp_named Surface_name.Term fmt name
      | None -> Format.fprintf fmt "#group[%d]" index)
  | Kernel.Lam (params, body) ->
      let params_meta = Meta.surface_container "params" expr.meta in
      Format.fprintf fmt "@[<hov 2>fn ";
      pp_leading context params_meta fmt;
      Format.fprintf fmt "(%a" (pp_sep "," (pp_pat context lookup)) params;
      pp_inner context params_meta fmt;
      Format.fprintf fmt ")";
      pp_trailing context params_meta fmt;
      Format.fprintf fmt " ->@ %a@]" (pp_expr context lookup) body
  | Kernel.App (fn, args) ->
      Format.fprintf fmt "@[<hov 2>%a(@,%a" (pp_expr_atom context lookup) fn
        (pp_sep "," (pp_expr context lookup))
        args;
      pp_inner context expr.meta fmt;
      Format.fprintf fmt ")@]"
  | Kernel.Let _ -> pp_block context lookup fmt expr
  | Kernel.Tuple items -> (
      match items with
      | [] -> Format.pp_print_string fmt "()"
      | [ item ] ->
          Format.fprintf fmt "(@[<hov>%a," (pp_expr context lookup) item;
          pp_inner context expr.meta fmt;
          Format.fprintf fmt "@])"
      | _ ->
          Format.fprintf fmt "(@[<hov>%a" (pp_sep "," (pp_expr context lookup)) items;
          pp_inner context expr.meta fmt;
          Format.fprintf fmt "@])")
  | Kernel.Ann (subject, ty) ->
      Format.fprintf fmt "@[<hov 2>(%a :@ %a" (pp_expr context lookup) subject
        (pp_ty context lookup) ty;
      pp_inner context expr.meta fmt;
      Format.fprintf fmt ")@]"
  | Kernel.Match (subject, clauses) -> pp_match context lookup expr.meta fmt subject clauses
  | Kernel.Handle { body; ret; ops } -> pp_handle context lookup expr.meta fmt body ret ops
  | Kernel.Quote payload -> pp_quote context lookup expr.meta fmt payload
  | Kernel.Unquote splice ->
      Format.fprintf fmt "unquote(%a" (pp_expr context lookup) splice;
      pp_inner context expr.meta fmt;
      Format.pp_print_char fmt ')'

and if_branches = function
  | [
      { Kernel.cpat = { it = Kernel.PCon (_, []); meta = true_meta }; cbody = yes; _ };
      { Kernel.cpat = { it = Kernel.PCon (_, []); meta = false_meta }; cbody = no; _ };
    ]
    when Meta.surface_form true_meta = Some "if-true"
         && Meta.surface_form false_meta = Some "if-false" ->
      Some (yes, no)
  | _ -> None

and expression_has_trailing_comments (expression : Kernel.expr) =
  let has meta = Meta.comment_texts Meta.key_trivia_trailing meta <> [] in
  has expression.meta
  || List.exists
       (fun kind -> has (Meta.surface_container kind expression.meta))
       [ "list"; "paren"; "block" ]

and pp_following_keyword context fmt expression keyword =
  if context.trivia && expression_has_trailing_comments expression then begin
    Format.pp_force_newline fmt ();
    Format.pp_print_string fmt keyword
  end
  else Format.fprintf fmt "@ %s" keyword

and pp_if context lookup fmt condition yes no =
  let rec pp_else fmt expression =
    match (Meta.surface_form expression.Kernel.meta, expression.it) with
    | Some "if", Kernel.Match (condition, clauses) -> (
        match if_branches clauses with
        | Some (yes, no) ->
            Format.pp_print_string fmt "else ";
            pp_leading context expression.meta fmt;
            Format.fprintf fmt "@[<hov 2>if %a" (pp_expr context lookup) condition;
            pp_following_keyword context fmt condition "then";
            Format.fprintf fmt "@ %a@]" (pp_expr context lookup) yes;
            if context.trivia && expression_has_trailing_comments yes then
              Format.pp_force_newline fmt ();
            Format.fprintf fmt "@ %a" pp_else no;
            pp_trailing context expression.meta fmt
        | None -> Format.fprintf fmt "else %a" (pp_expr context lookup) expression)
    | _ -> Format.fprintf fmt "else %a" (pp_expr context lookup) expression
  in
  Format.fprintf fmt "@[<hov 0>@[<hov 2>if %a" (pp_expr context lookup) condition;
  pp_following_keyword context fmt condition "then";
  Format.fprintf fmt "@ %a@]" (pp_expr context lookup) yes;
  if context.trivia && expression_has_trailing_comments yes then Format.pp_force_newline fmt ();
  Format.fprintf fmt "@ %a@]" pp_else no

and list_items expr =
  let rec collect acc current =
    match current.Kernel.it with
    | Kernel.App (fn, [ item; tail ])
      when (Meta.surface_form fn.meta = Some "list-cons-constructor"
           || Meta.surface_generated fn.meta = Some "list-cons-constructor")
           && (Meta.surface_form current.meta = Some "list"
              || Meta.surface_form current.meta = Some "list-tail") ->
        collect (item :: acc) tail
    | (Kernel.Var _ | Kernel.Ref _)
      when Meta.surface_form current.meta = Some "list-nil"
           || Meta.surface_generated current.meta = Some "list-nil" ->
        Some (List.rev acc)
    | _ -> None
  in
  collect [] expr

and pp_list context lookup meta fmt items =
  let container_meta = Meta.surface_container "list" meta in
  pp_leading context container_meta fmt;
  Format.fprintf fmt "[@[<hov>%a" (pp_sep "," (pp_expr context lookup)) items;
  pp_inner context meta fmt;
  pp_inner context container_meta fmt;
  Format.fprintf fmt "@]]";
  pp_trailing context container_meta fmt

and pp_pipe context lookup meta fmt left fn args =
  let rhs_meta = Meta.surface_container "pipe-rhs" meta in
  let explicit_call = Meta.surface_form rhs_meta = Some "pipe-call" in
  let pp_operator fmt () =
    if context.trivia && expression_has_trailing_comments left then Format.pp_force_newline fmt ();
    Format.pp_print_string fmt "|> ";
    pp_leading context rhs_meta fmt
  in
  match args with
  | [] when not explicit_call ->
      Format.fprintf fmt "@[<hov 2>%a@ %a%a" (pp_pipe_left context lookup) left pp_operator ()
        (pp_pipe_value context lookup) fn;
      pp_inner context rhs_meta fmt;
      pp_trailing context rhs_meta fmt;
      pp_inner context meta fmt;
      Format.fprintf fmt "@]"
  | _ ->
      Format.fprintf fmt "@[<hov 2>%a@ %a%a(@,%a" (pp_pipe_left context lookup) left pp_operator ()
        (pp_expr_atom context lookup) fn
        (pp_sep "," (pp_expr context lookup))
        args;
      pp_inner context rhs_meta fmt;
      pp_inner context meta fmt;
      Format.fprintf fmt ")";
      pp_trailing context rhs_meta fmt;
      Format.fprintf fmt "@]"

and pp_pipe_left context lookup fmt expr = pp_expr_atom context lookup fmt expr

and pp_pipe_value context lookup fmt expr =
  let block_meta = Meta.surface_container "block" expr.Kernel.meta in
  let paren_meta = Meta.surface_container "paren" expr.meta in
  if not (Meta.is_empty paren_meta) then pp_grouped context lookup paren_meta fmt expr
  else if not (Meta.is_empty block_meta) then pp_singleton_block context lookup block_meta fmt expr
  else pp_expr_atom context lookup fmt expr

and pp_grouped context lookup paren_meta fmt expr =
  pp_leading context paren_meta fmt;
  let expr = { expr with Kernel.meta = Meta.without_surface_container "paren" expr.meta } in
  Format.fprintf fmt "(@[<hov>%a" (pp_expr context lookup) expr;
  pp_inner context paren_meta fmt;
  Format.fprintf fmt "@])";
  pp_trailing context paren_meta fmt

and pp_singleton_block context lookup block_meta fmt expr =
  pp_leading context block_meta fmt;
  let expr = { expr with Kernel.meta = Meta.without_surface_container "block" expr.meta } in
  Format.fprintf fmt "@[<v 2>{@,%a" (pp_expr context lookup) expr;
  pp_inner context block_meta fmt;
  Format.fprintf fmt "@]@,}";
  pp_trailing context block_meta fmt

and pp_expr_atom context lookup fmt expr =
  let paren_meta = Meta.surface_container "paren" expr.Kernel.meta in
  if not (Meta.is_empty paren_meta) then pp_grouped context lookup paren_meta fmt expr
  else if
    match (Meta.surface_form expr.meta, expr.it) with
    | Some "if", Kernel.Match (_, clauses) -> Option.is_some (if_branches clauses)
    | _ -> false
  then Format.fprintf fmt "(%a)" (pp_expr context lookup) expr
  else
    match expr.Kernel.it with
    | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.App _ | Kernel.Match _
    | Kernel.Tuple _ | Kernel.Let _ | Kernel.Handle _ | Kernel.Quote _ | Kernel.Unquote _
    | Kernel.Ann _ ->
        pp_expr context lookup fmt expr
    | Kernel.Lam _ -> Format.fprintf fmt "(%a)" (pp_expr context lookup) expr

and pp_sequence_item context lookup fmt (meta, isrec, binder, value) =
  pp_leading context meta fmt;
  match (isrec, binder.Kernel.it, value.Kernel.it) with
  | false, Kernel.PWild, _
    when not (Option.equal String.equal (Meta.surface_form meta) (Some "let")) ->
      pp_expr context lookup fmt value;
      pp_trailing context meta fmt
  | true, Kernel.PVar name, Kernel.Lam (params, body) ->
      let params_meta = Meta.surface_container "params" value.meta in
      Format.fprintf fmt "@[<hov 2>let rec %a" (pp_named Surface_name.Term) name;
      pp_leading context params_meta fmt;
      Format.fprintf fmt "(%a" (pp_sep "," (pp_pat context lookup)) params;
      pp_inner context params_meta fmt;
      Format.fprintf fmt ")";
      pp_trailing context params_meta fmt;
      Format.fprintf fmt " =@ %a@]" (pp_expr context lookup) body;
      pp_trailing context meta fmt
  | _ ->
      Format.fprintf fmt "@[<hov 2>let%s %a =@ %a@]"
        (if isrec then " rec" else "")
        (pp_pat context lookup) binder (pp_expr context lookup) value;
      pp_trailing context meta fmt

and pp_block context lookup fmt expr =
  let rec collect acc current =
    match current.Kernel.it with
    | Kernel.Let { isrec; binder; value; body } ->
        collect ((current.Kernel.meta, isrec, binder, value) :: acc) body
    | _ -> (List.rev acc, current)
  in
  let lets, result = collect [] expr in
  let container_meta = Meta.surface_container "block" expr.Kernel.meta in
  let container_meta = if Meta.is_empty container_meta then expr.Kernel.meta else container_meta in
  pp_leading context container_meta fmt;
  Format.fprintf fmt "@[<v 2>{@,%a" (pp_sep "" (pp_sequence_item context lookup)) lets;
  if lets <> [] then Format.fprintf fmt "@,";
  Format.fprintf fmt "%a" (pp_expr context lookup) result;
  pp_inner context container_meta fmt;
  Format.fprintf fmt "@]@,}";
  pp_trailing context container_meta fmt

and pp_match context lookup meta fmt subject clauses =
  let pp_clause fmt (clause : Kernel.clause) =
    pp_leading context clause.cmeta fmt;
    match clause.cbody.it with
    | Kernel.Let _ ->
        Format.fprintf fmt "@[<v 2>| %a -> {@,%a@]@,}" (pp_pat context lookup) clause.cpat
          (pp_sequence_contents context lookup)
          clause.cbody;
        pp_trailing context clause.cmeta fmt
    | _ ->
        Format.fprintf fmt "@[<hov 2>| %a ->@ %a@]" (pp_pat context lookup) clause.cpat
          (pp_expr context lookup) clause.cbody;
        pp_trailing context clause.cmeta fmt
  in
  Format.fprintf fmt "@[<v 2>match %a {@,%a" (pp_expr context lookup) subject (pp_sep "" pp_clause)
    clauses;
  pp_inner context meta fmt;
  Format.fprintf fmt "@]@,}"

and pp_arm_body context lookup fmt body =
  match body.Kernel.it with
  | Kernel.Let _ -> pp_block context lookup fmt body
  | _ -> pp_expr context lookup fmt body

and pp_sequence_contents context lookup fmt expr =
  let rec collect acc current =
    match current.Kernel.it with
    | Kernel.Let { isrec; binder; value; body } ->
        collect ((current.Kernel.meta, isrec, binder, value) :: acc) body
    | _ -> (List.rev acc, current)
  in
  let lets, result = collect [] expr in
  pp_sep "" (pp_sequence_item context lookup) fmt lets;
  if lets <> [] then Format.fprintf fmt "@,";
  pp_expr context lookup fmt result

and pp_handle context lookup meta fmt body ret ops =
  let pp_resume fmt name =
    if String.equal name "_" then Format.pp_print_string fmt "_"
    else pp_named Surface_name.Term fmt name
  in
  let pp_ret fmt (clause : Kernel.ret) =
    pp_leading context clause.rmeta fmt;
    Format.fprintf fmt "@[<hov 2>| return %a ->@ %a@]" (pp_pat context lookup) clause.rbinder
      (pp_arm_body context lookup) clause.rbody;
    pp_trailing context clause.rmeta fmt
  in
  let pp_op fmt (clause : Kernel.opclause) =
    let params_meta = Meta.surface_container "params" clause.ometa in
    pp_leading context clause.ometa fmt;
    Format.fprintf fmt "@[<hov 2>| %a" (pp_gref lookup Surface_name.Op clause.ometa) clause.op;
    pp_leading context params_meta fmt;
    Format.fprintf fmt "(%a" (pp_sep "," (pp_pat context lookup)) clause.params;
    pp_inner context params_meta fmt;
    Format.fprintf fmt ")";
    pp_trailing context params_meta fmt;
    Format.fprintf fmt " resume %a ->@ %a@]" pp_resume clause.resume (pp_arm_body context lookup)
      clause.obody;
    pp_trailing context clause.ometa fmt
  in
  Format.fprintf fmt "@[<v 2>handle";
  (if is_atomic body then Format.fprintf fmt " %a {" (pp_expr context lookup) body
   else
     match body.Kernel.it with
     | Kernel.Let _ ->
         Format.fprintf fmt " {@,%a@;<0 -2>} {" (pp_sequence_contents context lookup) body
     | _ -> Format.fprintf fmt " {@,%a@;<0 -2>} {" (pp_expr context lookup) body);
  Format.fprintf fmt "@,%a" pp_ret ret;
  List.iter (fun clause -> Format.fprintf fmt "@,%a" pp_op clause) ops;
  pp_inner context meta fmt;
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

and pp_quote context lookup meta fmt payload =
  match surface_quote_expr payload with
  | Some expr ->
      Format.fprintf fmt "@[<hov 2>quote {@ %a" (pp_expr context lookup) expr;
      pp_inner context meta fmt;
      Format.fprintf fmt "@ }@]"
  | None ->
      let raw = jqd_block context payload in
      if String.contains raw '\n' then Format.fprintf fmt "quote {@,%s@,}" (indent_lines 2 raw)
      else Format.fprintf fmt "quote { %s }" raw

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

let pp_binding context lookup fmt (binding : Kernel.binding) =
  let pp_definition fmt () =
    pp_leading context binding.bmeta fmt;
    match binding.value.it with
    | Kernel.Lam (params, body)
      when not (Option.equal String.equal (Meta.surface_form binding.value.meta) (Some "fn")) ->
        let params_meta = Meta.surface_container "params" binding.bmeta in
        let params_meta =
          if Meta.is_empty params_meta then Meta.surface_container "params" binding.value.meta
          else params_meta
        in
        Format.fprintf fmt "@[<hov 2>%a" (pp_named Surface_name.Term) binding.bname;
        pp_leading context params_meta fmt;
        Format.fprintf fmt "(%a" (pp_sep "," (pp_pat context lookup)) params;
        pp_inner context params_meta fmt;
        Format.fprintf fmt ")";
        pp_trailing context params_meta fmt;
        Format.fprintf fmt " =@ %a@]" (pp_expr context lookup) body
    | _ ->
        Format.fprintf fmt "@[<hov 2>%a =@ %a@]" (pp_named Surface_name.Term) binding.bname
          (pp_expr context lookup) binding.value
  in
  match binding.annot with
  | None ->
      pp_definition fmt ();
      pp_trailing context binding.bmeta fmt
  | Some ty ->
      let signature_meta = Meta.signature binding.bmeta in
      pp_leading context signature_meta fmt;
      Format.fprintf fmt "@[<v>%a : %a" (pp_named Surface_name.Term) binding.bname
        (pp_ty context lookup) ty;
      pp_trailing context signature_meta fmt;
      Format.fprintf fmt "@,%a@]" pp_definition ();
      pp_trailing context binding.bmeta fmt

let pp_field context lookup fmt (field : Kernel.field) =
  pp_leading context field.fmeta fmt;
  (match field.label with
  | None -> pp_ty context lookup fmt field.fty
  | Some label ->
      Format.fprintf fmt "%a: %a" (pp_named Surface_name.Term) label (pp_ty context lookup)
        field.fty);
  pp_trailing context field.fmeta fmt

let pp_constructor ?(leading = true) context lookup fmt (constructor : Kernel.conspec) =
  if leading then pp_leading context constructor.kmeta fmt;
  Format.fprintf fmt "@[<hov>";
  pp_named Surface_name.Con fmt constructor.con_name;
  if constructor.fields <> [] then
    if List.exists (fun field -> Option.is_some field.Kernel.label) constructor.fields then begin
      let params_meta = Meta.surface_container "params" constructor.kmeta in
      pp_leading context params_meta fmt;
      Format.fprintf fmt "(@[<hov>%a" (pp_sep "," (pp_field context lookup)) constructor.fields;
      pp_inner context params_meta fmt;
      Format.fprintf fmt "@])"
    end
    else
      List.iter
        (fun field -> Format.fprintf fmt "@ %a" (pp_ty_atom context lookup) field.Kernel.fty)
        constructor.fields;
  Format.fprintf fmt "@]";
  pp_trailing context constructor.kmeta fmt

let pp_operation context lookup fmt (operation : Kernel.opspec) =
  let params_meta = Meta.surface_container "params" operation.smeta in
  pp_leading context operation.smeta fmt;
  Format.fprintf fmt "@[<hov 2>%a :@ " (pp_named Surface_name.Op) operation.op_name;
  pp_leading context params_meta fmt;
  Format.fprintf fmt "(%a" (pp_sep "," (pp_ty context lookup)) operation.op_params;
  pp_inner context params_meta fmt;
  Format.fprintf fmt ")";
  pp_trailing context params_meta fmt;
  Format.fprintf fmt " ->@ %a@]" (pp_ty context lookup) operation.op_result;
  pp_trailing context operation.smeta fmt

let pp_decl context lookup fmt (decl : Kernel.decl) =
  pp_leading context decl.meta fmt;
  (match decl.it with
  | Kernel.DefTerm bindings ->
      if not (printable_term_group bindings) then raise Bug_unsupported_surface_form;
      Format.fprintf fmt "@[<v>%a@]" (pp_sep "" (pp_binding context lookup)) bindings
  | Kernel.DefType { tname; tvars; cons } ->
      Format.fprintf fmt "@[<hov 2>type %a" (pp_named Surface_name.Type) tname;
      List.iter (fun name -> Format.fprintf fmt "@ %a" (pp_named Surface_name.Tvar) name) tvars;
      Format.fprintf fmt "@ =@ @[<hv>";
      List.iteri
        (fun index constructor ->
          if index > 0 then Format.fprintf fmt "@ ";
          pp_leading context constructor.Kernel.kmeta fmt;
          Format.fprintf fmt "| %a" (pp_constructor ~leading:false context lookup) constructor)
        cons;
      pp_inner context decl.meta fmt;
      Format.fprintf fmt "@]@]"
  | Kernel.DefEffect { ename; evars; ops } ->
      Format.fprintf fmt "@[<v 2>effect %a" (pp_named Surface_name.Effect) ename;
      List.iter (fun name -> Format.fprintf fmt " %a" (pp_named Surface_name.Tvar) name) evars;
      Format.fprintf fmt " where {@,%a" (pp_sep "" (pp_operation context lookup)) ops;
      pp_inner context decl.meta fmt;
      Format.fprintf fmt "@]@,}");
  pp_trailing context decl.meta fmt

let top_meta = function
  | Kernel.Expr expr -> expr.Kernel.meta
  | Kernel.Decl decl -> decl.Kernel.meta

let raw_top context top =
  let outer_meta = top_meta top in
  let bootstrap_meta = Meta.surface_container "bootstrap" outer_meta in
  let bootstrap_top =
    if Meta.is_empty bootstrap_meta then top
    else
      match top with
      | Kernel.Expr expr -> Kernel.Expr { expr with Kernel.meta = bootstrap_meta }
      | Kernel.Decl decl -> Kernel.Decl { decl with Kernel.meta = bootstrap_meta }
  in
  let form = Kernel.to_form bootstrap_top in
  let body = jqd_block context form in
  if not context.trivia then body
  else
    let leading = leading_comments outer_meta in
    let trailing = Meta.comment_texts Meta.key_trivia_trailing outer_meta in
    let prefix = match leading with [] -> "" | comments -> String.concat "\n" comments ^ "\n" in
    prefix ^ body ^ String.concat "" (List.map (fun comment -> " " ^ comment) trailing)

let is_decoded_surface_ref meta =
  match (Meta.surface_form meta, Meta.surface_ref_kind meta) with
  | Some form, Some ("con" | "op") -> String.equal form Kernel.surface_ref_head
  | _ -> false

(* A decoded marker in executable syntax cannot be printed as an escaped surface name: reparsing
   that spelling creates ordinary surface provenance and [expr_to_form] then emits [(var name)].
   Quote payload data is otherwise opaque here because quote lowering structurally re-encodes
   constructor and operation references. Live unquotes are executable boundaries, so they are
   decoded and inspected using the same quasiquote-level rule as resolution and hashing. *)
let rec has_decoded_surface_ref_expr (expr : Kernel.expr) =
  match expr.it with
  | Kernel.Var _ -> is_decoded_surface_ref expr.meta
  | Kernel.Lam (_, body) | Kernel.Unquote body | Kernel.Ann (body, _) ->
      has_decoded_surface_ref_expr body
  | Kernel.App (fn, args) ->
      has_decoded_surface_ref_expr fn || List.exists has_decoded_surface_ref_expr args
  | Kernel.Let { value; body; _ } ->
      has_decoded_surface_ref_expr value || has_decoded_surface_ref_expr body
  | Kernel.Match (subject, clauses) ->
      has_decoded_surface_ref_expr subject
      || List.exists (fun clause -> has_decoded_surface_ref_expr clause.Kernel.cbody) clauses
  | Kernel.Tuple items -> List.exists has_decoded_surface_ref_expr items
  | Kernel.Handle { body; ret; ops } ->
      has_decoded_surface_ref_expr body
      || has_decoded_surface_ref_expr ret.Kernel.rbody
      || List.exists (fun op -> has_decoded_surface_ref_expr op.Kernel.obody) ops
  | Kernel.Quote payload -> has_decoded_surface_ref_quote_payload payload
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ -> false

and has_decoded_surface_ref_quote_payload ?(level = 0) (form : Form.t) =
  if String.equal form.Form.head "unquote" && level = 0 then
    match form.Form.args with
    | [ Form.F splice ] -> (
        match Kernel.expr_of_form splice with
        | Ok expr -> has_decoded_surface_ref_expr expr
        | Error _ -> false)
    | _ -> false
  else
    let level =
      match form.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    List.exists
      (function Form.F child -> has_decoded_surface_ref_quote_payload ~level child | _ -> false)
      form.Form.args

let has_decoded_surface_ref_top = function
  | Kernel.Expr expr -> has_decoded_surface_ref_expr expr
  | Kernel.Decl { Kernel.it = DefTerm bindings; _ } ->
      List.exists (fun binding -> has_decoded_surface_ref_expr binding.Kernel.value) bindings
  | Kernel.Decl { Kernel.it = DefType _ | DefEffect _; _ } -> false

let is_raw_top top =
  match Meta.surface_form (top_meta top) with Some "raw-top" -> true | Some _ | None -> false

let render ~width pp value =
  let buffer = Buffer.create 128 in
  let fmt = Format.formatter_of_buffer buffer in
  Format.pp_set_margin fmt width;
  pp fmt value;
  Format.pp_print_flush fmt ();
  Buffer.contents buffer

let pp_clause_fragment context lookup fmt (clause : Kernel.clause) =
  match clause.cbody.it with
  | Kernel.Let _ ->
      Format.fprintf fmt "@[<v 2>| %a -> {@,%a@]@,}" (pp_pat context lookup) clause.cpat
        (pp_sequence_contents context lookup)
        clause.cbody
  | _ ->
      Format.fprintf fmt "@[<hov 2>| %a ->@ %a@]" (pp_pat context lookup) clause.cpat
        (pp_expr context lookup) clause.cbody

let pp_ret_fragment context lookup fmt (clause : Kernel.ret) =
  Format.fprintf fmt "@[<hov 2>| return %a ->@ %a@]" (pp_pat context lookup) clause.rbinder
    (pp_arm_body context lookup) clause.rbody

let pp_op_fragment context lookup fmt (clause : Kernel.opclause) =
  let pp_resume fmt name =
    if String.equal name "_" then Format.pp_print_string fmt "_"
    else pp_named Surface_name.Term fmt name
  in
  Format.fprintf fmt "@[<hov 2>| %a(%a) resume %a ->@ %a@]"
    (pp_gref lookup Surface_name.Op clause.ometa)
    clause.op
    (pp_sep "," (pp_pat context lookup))
    clause.params pp_resume clause.resume (pp_arm_body context lookup) clause.obody

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
  | Ok (Kernel.Expr expr) -> rendered (pp_expr canonical_context lookup) expr
  | Ok (Kernel.Decl decl) -> rendered (pp_decl canonical_context lookup) decl
  | Error _ -> (
      match Kernel.pat_of_form form with
      | Ok pat -> rendered (pp_pat canonical_context lookup) pat
      | Error _ -> (
          match Kernel.ty_of_form form with
          | Ok ty -> rendered (pp_ty canonical_context lookup) ty
          | Error _ -> (
              match Kernel.row_of_form form with
              | Ok row -> rendered (pp_row canonical_context lookup) row
              | Error _ -> (
                  match form.head with
                  | "clause" -> (
                      let wrapper = Form.form "match" [ Form.F dummy_lit; Form.F form ] in
                      match Kernel.expr_of_form wrapper with
                      | Ok { Kernel.it = Kernel.Match (_, [ clause ]); _ } ->
                          rendered (pp_clause_fragment canonical_context lookup) clause
                      | _ -> fragment_error form)
                  | "ret" -> (
                      let wrapper = Form.form "handle" [ Form.F dummy_lit; Form.F form ] in
                      match Kernel.expr_of_form wrapper with
                      | Ok { Kernel.it = Kernel.Handle { ret; _ }; _ } ->
                          rendered (pp_ret_fragment canonical_context lookup) ret
                      | _ -> fragment_error form)
                  | "opclause" -> (
                      let wrapper =
                        Form.form "handle" [ Form.F dummy_lit; Form.F dummy_ret; Form.F form ]
                      in
                      match Kernel.expr_of_form wrapper with
                      | Ok { Kernel.it = Kernel.Handle { ops = [ op ]; _ }; _ } ->
                          rendered (pp_op_fragment canonical_context lookup) op
                      | _ -> fragment_error form)
                  | "binding" -> (
                      let group = Form.form "group" [ Form.F form ] in
                      let wrapper = Form.form "defterm" [ Form.F group ] in
                      match Kernel.decl_of_form wrapper with
                      | Ok { Kernel.it = Kernel.DefTerm [ binding ]; _ } ->
                          rendered (pp_binding canonical_context lookup) binding
                      | _ -> fragment_error form)
                  | "con" -> (
                      let vars = Form.form "group" [] in
                      let wrapper =
                        Form.form "deftype" [ Form.Sym "fragment"; Form.F vars; Form.F form ]
                      in
                      match Kernel.decl_of_form wrapper with
                      | Ok { Kernel.it = Kernel.DefType { cons = [ constructor ]; _ }; _ } ->
                          rendered (pp_constructor canonical_context lookup) constructor
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
                          rendered (pp_field canonical_context lookup) field
                      | _ -> fragment_error form)
                  | "op" -> (
                      let vars = Form.form "group" [] in
                      let wrapper =
                        Form.form "defeffect" [ Form.Sym "fragment"; Form.F vars; Form.F form ]
                      in
                      match Kernel.decl_of_form wrapper with
                      | Ok { Kernel.it = Kernel.DefEffect { ops = [ operation ]; _ }; _ } ->
                          rendered (pp_operation canonical_context lookup) operation
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
let print_top_in context ?(lookup : lookup option) ?(width = default_width) (top : Kernel.top) :
    (string, Diag.t list) result =
  match top with
  | Kernel.Decl decl when is_surface_generated_decl decl -> Ok ""
  | _ when is_raw_top top -> Ok (raw_top context top)
  | _ when has_decoded_surface_ref_top top -> Ok (raw_top context top)
  | _ -> (
      match
        match top with
        | Kernel.Expr expr -> render ~width (pp_expr context lookup) expr
        | Kernel.Decl decl -> render ~width (pp_decl context lookup) decl
      with
      | text -> Ok text
      | exception Bug_unsupported_surface_form -> Ok (raw_top context top))

let print_top ?lookup ?width top = print_top_in canonical_context ?lookup ?width top

(** [print_file] renders a complete canonical surface file with one trailing newline. *)
let print_file_in context ?(lookup : lookup option) ?(width = default_width)
    (tops : Kernel.top list) : (string, Diag.t list) result =
  let rec loop acc = function
    | [] ->
        let body = String.concat "\n\n" (List.rev acc) in
        Ok (if String.equal body "" then "" else body ^ "\n")
    | top :: rest -> (
        match print_top_in context ?lookup ~width top with
        | Ok "" -> loop acc rest
        | Ok text -> loop (text :: acc) rest
        | Error ds -> Error ds)
  in
  loop [] tops

let print_file ?lookup ?width tops = print_file_in canonical_context ?lookup ?width tops

let eof_top = function
  | Kernel.Expr expression -> Meta.comment_texts Meta.key_trivia_eof expression.Kernel.meta
  | Kernel.Decl declaration -> (
      let declaration_eof = Meta.comment_texts Meta.key_trivia_eof declaration.Kernel.meta in
      match declaration.it with
      | Kernel.DefTerm bindings ->
          declaration_eof
          @ List.concat_map
              (fun binding -> Meta.comment_texts Meta.key_trivia_eof binding.Kernel.bmeta)
              bindings
      | Kernel.DefType _ | Kernel.DefEffect _ -> declaration_eof)

(** [print_file_with_trivia] renders a canonical surface file while emitting owned comment/doc
    bytes. Layout atoms remain available to tools but formatting follows the canonical printer.
    Comment-free output is byte-identical to [print_file]. *)
let print_file_with_trivia ?(file_meta = Meta.empty) ?(lookup : lookup option)
    ?(width = default_width) (tops : Kernel.top list) : (string, Diag.t list) result =
  let render_file () =
    match print_file_in trivia_context ?lookup ~width tops with
    | Error _ as error -> error
    | Ok body ->
        let eof = List.concat_map eof_top tops @ Meta.comment_texts Meta.key_trivia_eof file_meta in
        if eof = [] then Ok body
        else
          let prefix = if String.equal body "" then "" else body in
          Ok (prefix ^ String.concat "\n" eof ^ "\n")
  in
  render_file ()

(** [print_recovered] canonically prints a complete recovery result when it is strict and lowers.
    Damaged input is replayed byte-for-byte so comments cannot cross recovery boundaries. *)
let print_recovered ?(lookup : lookup option) ?(width = default_width)
    (recovered : Surface_ast.recovered) : (string, Diag.t list) result =
  match Surface_parse.strict_file recovered with
  | Error _ -> Ok recovered.source
  | Ok file -> (
      match Surface_lower.lower_file file with
      | Error diagnostics -> Error diagnostics
      | Ok lowered -> print_file_with_trivia ~file_meta:lowered.meta ?lookup ~width lowered.tops)
