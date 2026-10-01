(** Canonical `.jac` printer.

    The printer consumes validated kernel trees, not {!Surface_ast}; it therefore defines canonical
    surface text independently of how permissive parsing becomes. Unsupported forms use the
    documented [jqd { ... }] inversion escape until their native surface rendering lands. *)

type lookup = Surface_name.kind -> Hash.t -> string option

(** The canonical formatter's byte-width target. A caller may request another width for an editor or
    diagnostic view, but the command-line formatter and calls that omit [width] use exactly 100.
    This is a layout target rather than a global physical-line postcondition: adjacent syntax
    outside a measured group, preserved source text, or a raw [jqd] inversion may still exceed it. A
    group that ends exactly at the target remains compact when the containing top-level unit's
    preflight also fits; otherwise the whole unit is rendered at the requested target. *)
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

(* Directly nested parentheses chain their containers: a group's container may hold the next inner
   group's container under the same key. *)
let rec paren_chain_has_comments meta =
  (not (Meta.is_empty meta))
  && (meta_has_comments meta || paren_chain_has_comments (Meta.surface_container "paren" meta))

(* A parenthesized type's group, its body, or a nested group owns comments. *)
let rec type_group_has_comments meta =
  (not (Meta.is_empty meta))
  && (meta_has_comments meta
     || meta_has_comments (Meta.surface_container "paren-body" meta)
     || type_group_has_comments (Meta.surface_container "paren" meta))

(* [meta] or any delimiter container recorded in it owns comments. *)
let rec meta_tree_has_comments meta =
  meta_has_comments meta
  || List.exists
       (fun (_, value) -> meta_tree_has_comments (Meta.meta_of_value value))
       (Meta.bindings (Meta.surface_containers meta))

(* Some node or delimiter anywhere inside [ty] owns comments: printing them breaks lines. *)
let rec type_owns_comments (ty : Kernel.ty) =
  meta_tree_has_comments ty.meta
  ||
  match ty.it with
  | Kernel.TRef _ | Kernel.TVar _ -> false
  | Kernel.TApp (head, args) -> List.exists type_owns_comments (head :: args)
  | Kernel.TArrow (params, row, result) ->
      meta_tree_has_comments row.wmeta || List.exists type_owns_comments (result :: params)
  | Kernel.TTuple items -> List.exists type_owns_comments items
  | Kernel.TForall (_, _, body) -> type_owns_comments body

(* [ty]'s printing begins with a comment written on its own line before it. *)
let type_starts_with_comment (ty : Kernel.ty) =
  leading_comments ty.meta <> [] || leading_comments (Meta.surface_container "paren" ty.meta) <> []

(* A source group keeps its parentheses whenever a comment lies anywhere in or around it: the
   comment's line break is then inside the delimiters, where it is legal. *)
let keeps_group context (ty : Kernel.ty) =
  let paren_meta = Meta.surface_container "paren" ty.meta in
  context.trivia
  && (not (Meta.is_empty paren_meta))
  && (type_group_has_comments paren_meta
     || type_owns_comments { ty with Kernel.meta = Meta.without_surface_container "paren" ty.meta }
     )

let pp_comments fmt comments =
  List.iter
    (fun comment ->
      Format.pp_print_string fmt comment;
      Format.pp_print_break fmt 1000 0)
    comments

let pp_leading context meta fmt = if context.trivia then pp_comments fmt (leading_comments meta)

(* A trailing line comment runs to the end of its physical line, so nothing may follow it there.
   [pp_trailing] emits such a comment without a break because most owners end a line anyway; an
   owner that continues on the same line (a separator, keyword, or closing delimiter) must first ask
   [ends_in_line_comment] and break when it answers yes. The probe renders the value once more with
   a zero-width marker after each trailing comment and reports whether the rendering ends with that
   marker, so it sees comments owned by any nested node without a per-form case analysis. Probes do
   not nest: inside a probe every nested site keeps its one-line spelling, which leaves the final
   token of the probed value unchanged. *)
let line_comment_marker = "\000"
let probing = Domain.DLS.new_key (fun () -> false)

let pp_trailing context meta fmt =
  if context.trivia then
    List.iter
      (fun comment ->
        Format.fprintf fmt " %s" comment;
        if Domain.DLS.get probing then Format.pp_print_as fmt 0 line_comment_marker)
      (Meta.comment_texts Meta.key_trivia_trailing meta)

let ends_in_line_comment context pp value =
  context.trivia
  && (not (Domain.DLS.get probing))
  &&
  let buffer = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buffer in
  Format.pp_set_margin fmt 1_000_000;
  Domain.DLS.set probing true;
  Fun.protect
    ~finally:(fun () -> Domain.DLS.set probing false)
    (fun () ->
      pp fmt value;
      Format.pp_print_flush fmt ());
  String.ends_with ~suffix:line_comment_marker (Buffer.contents buffer)

(* [pp_following_keyword] prints [keyword] after a value on the same line, or at the start of the
   next line when the value ends in a line comment. [pp_following_break] is the same for a
   position that otherwise takes an ordinary break, and [pp_closing] for a closing delimiter. *)
let pp_following_keyword fmt commented keyword =
  if commented then Format.pp_force_newline fmt () else Format.pp_print_char fmt ' ';
  Format.pp_print_string fmt keyword

let pp_following_break fmt commented text =
  if commented then Format.pp_force_newline fmt () else Format.pp_print_space fmt ();
  Format.pp_print_string fmt text

let pp_closing fmt commented delimiter =
  if commented then Format.pp_force_newline fmt ();
  Format.pp_print_string fmt delimiter

(* Space-separated items; an item after one that ends in a line comment starts a fresh line. *)
let pp_spaced context pp fmt items =
  ignore
    (List.fold_left
       (fun previous item ->
         (match previous with
         | None -> ()
         | Some previous ->
             if ends_in_line_comment context pp previous then Format.pp_force_newline fmt ()
             else Format.pp_print_space fmt ());
         pp fmt item;
         Some item)
       None items)

(* Like [pp_spaced], but the space never breaks: used where a line break would end the enclosing
   construct (positional fields, type arguments). A line comment still ends its line; it can only
   occur where the source broke the line, inside delimiters. *)
let pp_joined ?(starts_with_comment = fun _ -> false) context pp fmt items =
  ignore
    (List.fold_left
       (fun previous item ->
         (match previous with
         | None -> ()
         | Some previous ->
             if
               ends_in_line_comment context pp previous
               || (context.trivia && starts_with_comment item)
             then Format.pp_force_newline fmt ()
             else Format.pp_print_char fmt ' ');
         pp fmt item;
         Some item)
       None items)

(* Closes a [@[<v 2>...] brace group. The comment-free spelling keeps the enclosing box's break
   before [}], so only a final line comment forces the brace onto its own line. *)
let pp_close_brace fmt commented =
  Format.pp_close_box fmt ();
  if commented then Format.pp_force_newline fmt () else Format.pp_print_cut fmt ();
  Format.pp_print_char fmt '}'

(* Whether the last of [items], followed by the owner's inner comments, ends in a line comment.
   Inner comments always end with their own break, so only the last item can leave one open. *)
let ends_in_last_line_comment context pp meta items =
  context.trivia
  && Meta.comment_texts Meta.key_trivia_inner meta = []
  && match List.rev items with [] -> false | last :: _ -> ends_in_line_comment context pp last

let pp_line_trailing context meta fmt =
  if context.trivia then
    List.iter
      (fun comment ->
        Format.fprintf fmt " %s" comment;
        Format.pp_print_break fmt 1000 0)
      (Meta.comment_texts Meta.key_trivia_trailing meta)

let has_line_trailing context meta =
  context.trivia && Meta.comment_texts Meta.key_trivia_trailing meta <> []

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

let pp_owned_token context meta token fmt =
  pp_leading context meta fmt;
  pp_inner context meta fmt;
  Format.pp_print_string fmt token;
  pp_line_trailing context meta fmt

let owned kind meta = Meta.surface_container kind meta
let indexed kind index meta = Meta.surface_indexed_container kind index meta

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

(* Inside [jqd { ... }] the bootstrap reader treats only [;] as a comment starter, so a surface
   [--] comment copied verbatim would be read as a symbol and the escape would not reparse. Each
   comment is therefore carried as a bootstrap comment that keeps the original bytes after [; ].
   Bootstrap-spelled comments are unchanged, which keeps formatting idempotent. *)
let bootstrap_comment text = if String.starts_with ~prefix:";" text then text else "; " ^ text

let rec with_bootstrap_comments (form : Form.t) =
  let atom = function
    | Meta.Comment text -> Meta.Comment (bootstrap_comment text)
    | Meta.Doc text -> Meta.Doc (bootstrap_comment text)
    | Meta.Layout _ as layout -> layout
  in
  let meta =
    List.fold_left
      (fun meta key ->
        match Meta.trivia key meta with
        | [] -> meta
        | atoms -> Meta.with_trivia key (List.map atom atoms) meta)
      form.meta
      [ Meta.key_trivia; Meta.key_trivia_trailing; Meta.key_trivia_inner; Meta.key_trivia_eof ]
  in
  let args =
    List.map
      (function Form.F child -> Form.F (with_bootstrap_comments child) | arg -> arg)
      form.args
  in
  { form with meta; args }

let jqd_block context form =
  if context.trivia && has_comments form then
    "jqd {\n"
    ^ indent_lines 2 (drop_final_newline (Printer.format_all [ with_bootstrap_comments form ]))
    ^ "\n}"
  else "jqd { " ^ Printer.inline_form form ^ " }"

(** [render_name] is the printer's sole D34 spelling boundary. *)
let render_name = Surface_name.render

let pp_sep sep pp fmt items =
  List.iteri
    (fun i item ->
      if i > 0 then Format.fprintf fmt "%s@ " sep;
      pp fmt item)
    items

(* In an [hv] box every break is taken together. The opening break therefore puts the first item
   on its own line when the group does not fit, the separator breaks put every later item on its
   own line, and the final custom break adds a comma only in that vertical rendering. When comments
   follow the final comma, this helper owns their two breaks so the close still returns to the
   delimiter's column without an empty line. Singleton tuples opt into a comma in both layouts
   because the comma carries their arity. *)
let pp_comma_list ?(singleton = false) ?(trailing_comma = true) ?(leading_space = false)
    ?(break_padding = "") ?(inner_metas = []) context pp fmt items =
  let inner_comments =
    if context.trivia then List.concat_map (Meta.comment_texts Meta.key_trivia_inner) inner_metas
    else []
  in
  let last_commented = ref false in
  if items <> [] then begin
    Format.pp_print_custom_break fmt
      ~fits:("", (if leading_space then 1 else 0), "")
      ~breaks:("", 0, break_padding);
    let last = List.length items - 1 in
    List.iteri
      (fun index item ->
        pp fmt item;
        let commented = ends_in_line_comment context pp item in
        if index = last then last_commented := commented
        else if commented then begin
          (* The comment owns the rest of its line, so the separator opens the next line. *)
          Format.pp_print_break fmt 1000 0;
          Format.pp_print_string fmt break_padding;
          Format.pp_print_string fmt ", "
        end
        else Format.pp_print_custom_break fmt ~fits:(",", 1, "") ~breaks:(",", 0, break_padding))
      items
  end;
  (* After a commented final item the optional trailing comma is omitted; a singleton keeps its
     arity comma on the following line. *)
  let close_commented_last () =
    Format.pp_print_break fmt 1000 0;
    Format.pp_print_string fmt break_padding;
    if singleton then Format.pp_print_char fmt ','
  in
  match inner_comments with
  | [] ->
      if !last_commented then begin
        if singleton then close_commented_last ();
        Format.pp_print_break fmt 1000 (-2);
        Format.pp_print_string fmt break_padding
      end
      else if items <> [] then
        Format.pp_print_custom_break fmt
          ~fits:((if singleton then "," else ""), 0, "")
          ~breaks:((if trailing_comma then "," else ""), -2, break_padding)
  | comments ->
      if !last_commented then (if singleton then close_commented_last ())
      else if items <> [] && trailing_comma then Format.pp_print_char fmt ',';
      List.iter
        (fun comment ->
          Format.pp_print_break fmt 1000 0;
          Format.pp_print_string fmt break_padding;
          Format.pp_print_string fmt comment)
        comments;
      Format.pp_print_break fmt 1000 (-2);
      Format.pp_print_string fmt break_padding

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

let labeled_pattern_omission (pattern : Kernel.pat) =
  Meta.surface_generated pattern.meta = Some "labeled-pattern-omission"

let rec pp_pat context lookup fmt (pat : Kernel.pat) =
  pp_leading context pat.meta fmt;
  (match pat.it with
  | Kernel.PWild -> Format.pp_print_string fmt "_"
  | Kernel.PVar name -> pp_named Surface_name.Term fmt name
  | Kernel.PLit lit -> pp_lit fmt lit
  | Kernel.PCon (con, args) ->
      Format.fprintf fmt "@[<hv 2>";
      pp_gref lookup Surface_name.Con pat.meta fmt con;
      if args <> [] then begin
        let labeled = Meta.surface_form pat.meta = Some "labeled-pattern" in
        let args =
          if labeled then List.filter (fun arg -> not (labeled_pattern_omission arg)) args else args
        in
        let pp_arg = if labeled then pp_labeled_pat context lookup else pp_pat context lookup in
        Format.fprintf fmt "(%a" (pp_comma_list ~inner_metas:[ pat.meta ] context pp_arg) args;
        Format.fprintf fmt ")"
      end;
      Format.fprintf fmt "@]"
  | Kernel.PTuple items -> (
      match items with
      | [] ->
          Format.pp_print_char fmt '(';
          pp_inner context pat.meta fmt;
          Format.pp_print_char fmt ')'
      | [ item ] ->
          Format.fprintf fmt "@[<hv 2>(%a"
            (pp_comma_list ~singleton:true ~inner_metas:[ pat.meta ] context (pp_pat context lookup))
            [ item ];
          Format.fprintf fmt ")@]"
      | _ ->
          Format.fprintf fmt "@[<hv 2>(%a"
            (pp_comma_list ~inner_metas:[ pat.meta ] context (pp_pat context lookup))
            items;
          Format.fprintf fmt ")@]")
  | Kernel.PAs (name, inner) -> (
      match inner.it with
      | Kernel.PAs _ -> raise Bug_unsupported_surface_form
      | _ ->
          Format.fprintf fmt "@[<hov>%a as %a@]" (pp_pat context lookup) inner
            (pp_named Surface_name.Term) name));
  pp_trailing context pat.meta fmt

and pp_labeled_pat context lookup fmt (pattern : Kernel.pat) =
  match Meta.surface_pattern_label pattern.meta with
  | None -> raise Bug_unsupported_surface_form
  | Some label ->
      let field_meta = Meta.surface_container "pattern-field" pattern.meta in
      pp_leading context field_meta fmt;
      Format.fprintf fmt "@[<hov 2>%a:@ %a@]" (pp_named Surface_name.Term) label
        (pp_pat context lookup) pattern;
      pp_trailing context field_meta fmt

and pp_callable_pat context lookup fmt (pattern : Kernel.pat) =
  match Meta.surface_call_label pattern.meta with
  | None -> pp_pat context lookup fmt pattern
  | Some label ->
      let field_meta = Meta.surface_container "call-parameter" pattern.meta in
      pp_leading context field_meta fmt;
      Format.fprintf fmt "@[<hov 2>%a:@ %a@]" (pp_named Surface_name.Term) label
        (pp_pat context lookup) pattern;
      pp_trailing context field_meta fmt

and pp_row context lookup fmt (row : Kernel.row) =
  let opening = owned "row-open" row.wmeta in
  let closing = owned "row-close" row.wmeta in
  Format.pp_print_string fmt "->";
  pp_owned_token context opening "{" fmt;
  Format.fprintf fmt "@[<hv -1>";
  if not (has_line_trailing context opening) then Format.fprintf fmt "@;<0 0>";
  pp_leading context row.wmeta fmt;
  List.iteri
    (fun index effect_ref ->
      if index > 0 then begin
        let comma = indexed "row-comma" (index - 1) row.wmeta in
        pp_owned_token context comma "," fmt;
        if not (has_line_trailing context comma) then Format.fprintf fmt "@ "
      end;
      let effect_meta = indexed "row-effect" index row.wmeta in
      pp_leading context effect_meta fmt;
      pp_gref lookup Surface_name.Effect effect_meta fmt effect_ref;
      pp_line_trailing context effect_meta fmt)
    row.effects;
  (match row.rvar with
  | None -> ()
  | Some tail ->
      let preceding =
        if row.effects = [] then opening
        else indexed "row-effect" (List.length row.effects - 1) row.wmeta
      in
      if row.effects <> [] then begin
        let trailing_comma = indexed "row-comma" (List.length row.effects - 1) row.wmeta in
        if context.trivia && meta_has_comments trailing_comma then begin
          pp_leading context trailing_comma fmt;
          pp_inner context trailing_comma fmt;
          pp_line_trailing context trailing_comma fmt;
          if not (has_line_trailing context trailing_comma) then Format.fprintf fmt "@ "
        end
        else if not (has_line_trailing context preceding) then Format.fprintf fmt "@ "
      end;
      let bar_meta = owned "row-bar" row.wmeta in
      pp_owned_token context bar_meta "|" fmt;
      if not (has_line_trailing context bar_meta) then Format.pp_print_char fmt ' ';
      let tail_meta = owned "row-tail" row.wmeta in
      pp_leading context tail_meta fmt;
      pp_named Surface_name.Rvar fmt tail;
      pp_line_trailing context tail_meta fmt);
  pp_inner context row.wmeta fmt;
  let preceding =
    match row.rvar with
    | Some _ -> owned "row-tail" row.wmeta
    | None when row.effects <> [] -> indexed "row-effect" (List.length row.effects - 1) row.wmeta
    | None -> opening
  in
  if not (has_line_trailing context preceding) then
    begin match (row.effects, row.rvar) with
    | _ :: _, None ->
        let trailing_comma = indexed "row-comma" (List.length row.effects - 1) row.wmeta in
        if context.trivia && meta_has_comments trailing_comma then begin
          pp_leading context trailing_comma fmt;
          pp_inner context trailing_comma fmt;
          Format.pp_print_char fmt ',';
          pp_trailing context trailing_comma fmt;
          Format.pp_print_break fmt 1000 (-2)
        end
        else Format.pp_print_custom_break fmt ~fits:("", 0, "") ~breaks:(",", -2, "")
    | _, _ -> Format.fprintf fmt "@;<0 -2>"
    end;
  Format.fprintf fmt "@]";
  pp_owned_token context closing "}" fmt;
  pp_trailing context row.wmeta fmt

(* A parenthesized type that owns comments keeps its parentheses so the comments keep their place;
   comment-free groups are dropped as before. *)
and pp_ty context lookup fmt (ty : Kernel.ty) =
  let paren_meta = Meta.surface_container "paren" ty.meta in
  if keeps_group context ty then pp_grouped_ty context lookup paren_meta fmt ty
  else pp_plain_ty context lookup fmt ty

and pp_grouped_ty context lookup paren_meta fmt ty =
  (* the node's own comments were written outside the outermost parenthesis *)
  pp_leading context ty.meta fmt;
  pp_leading context paren_meta fmt;
  let inner = Meta.surface_container "paren" paren_meta in
  let body_meta = Meta.surface_container "paren-body" paren_meta in
  (* a body that is a tuple keeps the comments before its own [)] inside its delimiters *)
  let body_inner = Meta.trivia Meta.key_trivia_inner body_meta in
  let tuple = match ty.Kernel.it with Kernel.TTuple _ -> true | _ -> false in
  let own =
    ty.meta |> Meta.remove Meta.key_trivia
    |> Meta.remove Meta.key_trivia_trailing
    |> Meta.remove Meta.key_trivia_inner |> Meta.remove Meta.key_doc
  in
  let own = if tuple then Meta.with_trivia Meta.key_trivia_inner body_inner own else own in
  let body =
    {
      ty with
      Kernel.meta =
        (if type_group_has_comments inner then Meta.with_surface_container "paren" inner own
         else Meta.without_surface_container "paren" own);
    }
  in
  Format.fprintf fmt "(@[<hov>";
  pp_leading context body_meta fmt;
  pp_ty context lookup fmt body;
  pp_trailing context body_meta fmt;
  if has_line_trailing context body_meta then Format.pp_force_newline fmt ();
  (* comments before [)] may belong to the body or the group: one list, one layout *)
  pp_inner context
    (Meta.with_trivia Meta.key_trivia_inner
       ((if tuple then [] else body_inner) @ Meta.trivia Meta.key_trivia_inner paren_meta)
       Meta.empty)
    fmt;
  if ends_in_last_line_comment context (pp_ty context lookup) paren_meta [ body ] then
    Format.pp_force_newline fmt ();
  Format.fprintf fmt "@])";
  pp_trailing context paren_meta fmt;
  pp_trailing context ty.meta fmt

and pp_plain_ty context lookup fmt (ty : Kernel.ty) =
  pp_leading context ty.meta fmt;
  (match ty.it with
  | Kernel.TRef ref -> pp_gref lookup Surface_name.Type ty.meta fmt ref
  | Kernel.TVar name -> pp_named Surface_name.Tvar fmt name
  | Kernel.TApp (head, args) when context.trivia && List.exists type_owns_comments args ->
      (* a line break between a type and its arguments ends a signature or field: join them *)
      Format.fprintf fmt "@[<hov>%a@]"
        (pp_joined ~starts_with_comment:type_starts_with_comment context (pp_ty_atom context lookup))
        (head :: args)
  | Kernel.TApp (head, args) ->
      Format.fprintf fmt "@[<hov>%a@]" (pp_spaced context (pp_ty_atom context lookup)) (head :: args)
  | Kernel.TArrow (params, row, result) ->
      let params_meta = Meta.surface_container "params" ty.meta in
      Format.fprintf fmt "@[<hov 2>";
      pp_leading context params_meta fmt;
      (* `(T,)` spells a one-element tuple type, so a lone parameter never takes the trailing
         comma of the vertical layout. *)
      Format.fprintf fmt "(@[<hv 1>%a"
        (pp_comma_list
           ~trailing_comma:(List.length params <> 1)
           ~inner_metas:[ params_meta ] context (pp_ty context lookup))
        params;
      Format.fprintf fmt "@])";
      pp_trailing context params_meta fmt;
      if has_line_trailing context params_meta then Format.pp_force_newline fmt ()
      else Format.pp_print_char fmt ' ';
      pp_row context lookup fmt row;
      if not (has_line_trailing context (owned "row-close" row.wmeta)) then Format.fprintf fmt "@ ";
      Format.fprintf fmt "%a@]" (pp_ty context lookup) result
  | Kernel.TTuple items -> (
      match items with
      | [] ->
          Format.pp_print_char fmt '(';
          pp_inner context ty.meta fmt;
          Format.pp_print_char fmt ')'
      | [ item ] ->
          Format.fprintf fmt "@[<hv 2>(%a"
            (pp_comma_list ~singleton:true ~inner_metas:[ ty.meta ] context (pp_ty context lookup))
            [ item ];
          Format.fprintf fmt ")@]"
      | _ ->
          Format.fprintf fmt "@[<hv 2>(%a"
            (pp_comma_list ~inner_metas:[ ty.meta ] context (pp_ty context lookup))
            items;
          Format.fprintf fmt ")@]")
  | Kernel.TForall (tvars, rvars, body) ->
      let forall_meta = Meta.surface_container "forall" ty.meta in
      pp_leading context forall_meta fmt;
      Format.fprintf fmt "@[<hov 2>";
      pp_owned_token context (owned "forall-keyword" forall_meta) "forall" fmt;
      if tvars = [] && rvars = [] then Format.fprintf fmt "@ "
      else begin
        List.iteri
          (fun index name ->
            Format.pp_print_char fmt ' ';
            let meta = indexed "forall-tvar" index forall_meta in
            pp_leading context meta fmt;
            pp_named Surface_name.Tvar fmt name;
            pp_line_trailing context meta fmt)
          tvars;
        if rvars <> [] then begin
          Format.pp_print_char fmt ' ';
          pp_owned_token context (owned "forall-bar" forall_meta) "|" fmt;
          List.iteri
            (fun index name ->
              Format.pp_print_char fmt ' ';
              let meta = indexed "forall-rvar" index forall_meta in
              pp_leading context meta fmt;
              pp_named Surface_name.Rvar fmt name;
              pp_line_trailing context meta fmt)
            rvars
        end
      end;
      pp_inner context forall_meta fmt;
      let dot_meta = owned "forall-dot" forall_meta in
      pp_owned_token context dot_meta "." fmt;
      pp_trailing context forall_meta fmt;
      if not (has_line_trailing context dot_meta) then Format.fprintf fmt "@ ";
      Format.fprintf fmt "%a@]" (pp_ty context lookup) body);
  pp_trailing context ty.meta fmt

and pp_ty_atom context lookup fmt ty =
  match ty.Kernel.it with
  (* a group that owns comments already prints its own parentheses *)
  | (Kernel.TApp _ | Kernel.TArrow _ | Kernel.TForall _) when keeps_group context ty ->
      pp_ty context lookup fmt ty
  | Kernel.TApp _ | Kernel.TArrow _ | Kernel.TForall _ ->
      Format.fprintf fmt "(%a" (pp_ty context lookup) ty;
      pp_closing fmt (ends_in_line_comment context (pp_ty context lookup) ty) ")"
  | _ -> pp_ty context lookup fmt ty

and pp_callable_ty context lookup fmt (ty : Kernel.ty) =
  match Meta.surface_call_label ty.meta with
  | None -> pp_ty context lookup fmt ty
  | Some label ->
      let field_meta = Meta.surface_container "call-parameter" ty.meta in
      pp_leading context field_meta fmt;
      Format.fprintf fmt "@[<hov 2>%a:@ %a@]" (pp_named Surface_name.Term) label
        (pp_ty context lookup) ty;
      pp_trailing context field_meta fmt

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
  match reordered_named_call expr with
  | Some (fn, source_arguments) ->
      pp_reordered_named_call context lookup fmt expr fn source_arguments
  | None -> (
      match field_update_elaboration expr with
      | Some (fn, value, updates) ->
          pp_leading context expr.meta fmt;
          pp_field_update context lookup expr.meta fmt fn value updates;
          pp_trailing context expr.meta fmt
      | None -> pp_expr_regular context lookup fmt expr)

(* SX.28b: a field update `Ctor(value with label: e, ...)` lowers to one application tagged
   `field-update` whose first argument is the value and whose labeled arguments are the updates.
   Resolution elaborates it to the let-and-match twin; [field_update_elaboration] recognizes exactly
   that generated shape, so a resolved update prints back too. *)
and field_update_parts (expr : Kernel.expr) =
  match (Meta.surface_form expr.meta, expr.it) with
  | Some "field-update", Kernel.App (fn, value :: (_ :: _ as updates))
    when Option.is_none (Meta.surface_call_label value.meta)
         && List.for_all
              (fun (update : Kernel.expr) -> Option.is_some (Meta.surface_call_label update.meta))
              updates ->
      Some (fn, value, updates)
  | _ -> None

and field_update_elaboration (expr : Kernel.expr) =
  let generated marker (node : Kernel.expr) = Meta.surface_generated node.meta = Some marker in
  match expr.it with
  | Kernel.Let { isrec = false; binder = { it = Kernel.PVar value_name; _ }; value; body }
    when generated "field-update" expr ->
      let rec collect acc (current : Kernel.expr) =
        match current.it with
        | Kernel.Let { isrec = false; binder = { it = Kernel.PVar name; _ }; value; body }
          when generated "field-update-let" current ->
            collect ((name, value) :: acc) body
        | Kernel.Match
            ( { it = Kernel.Var subject; _ },
              [
                {
                  cpat = { it = Kernel.PCon (_, patterns); _ };
                  cbody = { it = App (fn, args); _ };
                  _;
                };
              ] )
          when String.equal subject value_name
               && generated "field-update-match" current
               && List.length patterns = List.length args ->
            let slots = List.combine patterns args in
            let label (name, (update : Kernel.expr)) =
              List.find_map
                (fun ((pattern : Kernel.pat), (argument : Kernel.expr)) ->
                  match argument.it with
                  | Kernel.Var used when String.equal used name ->
                      Option.map
                        (fun label ->
                          {
                            update with
                            Kernel.meta = Meta.with_surface_call_label label update.meta;
                          })
                        (Meta.surface_pattern_label pattern.meta)
                  | _ -> None)
                slots
            in
            let updates = List.map label (List.rev acc) in
            if updates <> [] && List.for_all Option.is_some updates then
              Some (fn, value, List.map Option.get updates)
            else None
        | _ -> None
      in
      collect [] body
  | _ -> None

and pp_field_update context lookup meta fmt fn value updates =
  Format.fprintf fmt "@[<hv 2>%a(%a" (pp_expr_atom context lookup) fn (pp_expr context lookup) value;
  pp_following_keyword fmt (ends_in_line_comment context (pp_expr context lookup) value) "with";
  pp_comma_list ~leading_space:true ~inner_metas:[ meta ] context (pp_call_argument context lookup)
    fmt updates;
  Format.fprintf fmt ")@]"

(* SX.29 (D77): a `try` block item lowers to a two-armed match tagged `try`/`try-bare` whose Ok arm
   is the rest of the block; the printer folds it back into the block it came from. *)
and try_item (expr : Kernel.expr) =
  (* Re-sugar only the exact expansion the lowering produces. Every generated node carries its own
     tag (clauses, both patterns, the Err binder, the constructor reference with constructor kind,
     the re-wrapped value), the payload is irrefutable (a wildcard for the bare form), and the Err
     arm re-wraps its own binder. Anything else carrying a `try` tag prints as the explicit match. *)
  let tagged form meta = Meta.surface_form meta = Some form in
  match (Meta.surface_form expr.meta, expr.it) with
  | ( Some (("try" | "try-bare") as form),
      Kernel.Match
        ( subject,
          [
            {
              cpat = { it = Kernel.PCon (Kernel.Named "ok", [ payload ]); meta = ok_meta };
              cbody;
              cmeta = ok_clause_meta;
            };
            {
              cpat =
                {
                  it =
                    Kernel.PCon
                      (Kernel.Named "err", [ { it = Kernel.PVar bound; meta = binder_meta } ]);
                  meta = err_meta;
                };
              cbody =
                {
                  it =
                    Kernel.App
                      ( { it = Kernel.Var "err"; meta = constructor_meta },
                        [ { it = Kernel.Var used; meta = value_meta } ] );
                  meta = rewrap_meta;
                };
              cmeta = err_clause_meta;
            };
          ] ) )
    when String.equal bound used
         && tagged "try-ok-clause" ok_clause_meta
         && tagged "try-err-clause" err_clause_meta
         && tagged "try-ok" ok_meta && tagged "try-err" err_meta
         && tagged "try-err-binder" binder_meta
         && tagged "try-err-constructor" constructor_meta
         && Meta.surface_ref_kind constructor_meta = Some "con"
         && tagged "try-err-value" value_meta
         && tagged "try-err-rewrap" rewrap_meta
         &&
         if form = "try" then Kernel.is_irrefutable payload
         else payload.Kernel.it = Kernel.PWild && tagged "try-discard" payload.Kernel.meta ->
      Some (form, payload, subject, cbody)
  | _ -> None

and is_block_expr (expr : Kernel.expr) =
  match expr.it with
  | Kernel.Let _ -> Option.is_none (field_update_elaboration expr)
  | _ -> Option.is_some (try_item expr)

and pp_expr_regular context lookup fmt (expr : Kernel.expr) =
  let block_meta = Meta.surface_container "block" expr.meta in
  let paren_meta = Meta.surface_container "paren" expr.meta in
  if context.trivia && paren_chain_has_comments paren_meta then
    pp_grouped context lookup paren_meta fmt expr
  else if context.trivia && (not (Meta.is_empty block_meta)) && meta_has_comments block_meta then
    if is_block_expr expr then pp_block context lookup fmt expr
    else pp_singleton_block context lookup block_meta fmt expr
  else begin
    if not (is_block_expr expr) then pp_leading context expr.meta fmt;
    (match (Meta.surface_form expr.meta, expr.it) with
    | Some ("try" | "try-bare"), Kernel.Match _ when is_block_expr expr ->
        pp_block context lookup fmt expr
    | Some "interpolation", Kernel.App (fn, args) -> (
        match interpolation_text context lookup fn args with
        | Some text -> Format.pp_print_string fmt text
        | None -> pp_kernel_expr context lookup fmt expr)
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
    | Some "field-update", Kernel.App _ -> (
        match field_update_parts expr with
        | Some (fn, value, updates) -> pp_field_update context lookup expr.meta fmt fn value updates
        | None -> pp_kernel_expr context lookup fmt expr)
    | Some _, _ | None, _ -> pp_kernel_expr context lookup fmt expr);
    if not (is_block_expr expr) then pp_trailing context expr.meta fmt
  end

and reordered_named_call (expr : Kernel.expr) =
  if Meta.surface_generated expr.meta <> Some "named-call-reordered" then None
  else
    let rec collect bindings (current : Kernel.expr) =
      match current.it with
      | Kernel.Let { isrec = false; binder = { it = Kernel.PVar name; _ }; value; body }
        when bindings = [] || Meta.surface_generated current.meta = Some "named-call-argument-let"
        ->
          collect ((name, value) :: bindings) body
      | Kernel.App (fn, arguments)
        when Meta.surface_generated current.meta = Some "named-call-positional-app" ->
          let bindings = List.rev bindings in
          let names = List.map fst bindings in
          let referenced =
            List.filter_map
              (fun argument ->
                match argument.Kernel.it with Kernel.Var name -> Some name | _ -> None)
              arguments
          in
          if
            List.length referenced = List.length arguments
            && List.sort String.compare referenced = List.sort String.compare names
          then Some (fn, List.map snd bindings)
          else None
      | _ -> None
    in
    collect [] expr

and pp_reordered_named_call context lookup fmt (expr : Kernel.expr) fn source_arguments =
  pp_leading context expr.meta fmt;
  (match (Meta.surface_form expr.meta, source_arguments) with
  | Some "pipe", left :: arguments -> pp_pipe context lookup expr.meta fmt left fn arguments
  | (Some _ | None), _ ->
      Format.fprintf fmt "@[<hv 2>%a(%a" (pp_expr_atom context lookup) fn
        (pp_comma_list ~inner_metas:[ expr.meta ] context (pp_call_argument context lookup))
        source_arguments;
      Format.fprintf fmt ")@]");
  pp_trailing context expr.meta fmt

and interpolation_text context lookup fn args =
  let is_text_join =
    match fn.Kernel.it with
    | Kernel.Var name -> String.equal name "text.join"
    | Kernel.Ref (hash, Kernel.Term) ->
        Option.equal String.equal (Meta.name fn.meta) (Some "text.join")
        || Option.equal String.equal
             (Option.bind lookup (fun find -> find Surface_name.Term hash))
             (Some "text.join")
    | Kernel.Ref (_, (Kernel.Con | Kernel.Op))
    | Kernel.GroupRef _ | Kernel.Lit _ | Kernel.Lam _ | Kernel.App _ | Kernel.Let _ | Kernel.Match _
    | Kernel.Tuple _ | Kernel.Handle _ | Kernel.Quote _ | Kernel.Unquote _ | Kernel.Ann _ ->
        false
  in
  let escape_text text =
    let escaped = Printer.escape_text text in
    let buffer = Buffer.create (String.length escaped) in
    String.iter
      (fun char ->
        if char = '{' then Buffer.add_string buffer "{{" else Buffer.add_char buffer char)
      escaped;
    Buffer.contents buffer
  in
  let render_expr part =
    let buffer = Buffer.create 64 in
    let formatter = Format.formatter_of_buffer buffer in
    Format.pp_set_margin formatter 1_000_000;
    pp_expr context lookup formatter part;
    Format.pp_print_flush formatter ();
    let rendered = Buffer.contents buffer in
    if String.contains rendered '\n' || String.contains rendered '\r' then None else Some rendered
  in
  let render_part (part : Kernel.expr) =
    match (part.it, Meta.surface_generated part.meta) with
    | Kernel.Lit (Kernel.LText text), Some "interpolation-text" -> Some (escape_text text)
    | _ -> Option.map (fun expression -> "{" ^ expression ^ "}") (render_expr part)
  in
  if not is_text_join then None
  else
    let rec collect acc = function
      | [] -> Some ("$\"" ^ String.concat "" (List.rev acc) ^ "\"")
      | part :: rest -> (
          match render_part part with
          | Some rendered -> collect (rendered :: acc) rest
          | None -> None)
    in
    collect [] args

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
      Format.fprintf fmt "@[<hv 2>fn ";
      pp_leading context params_meta fmt;
      Format.fprintf fmt "(%a"
        (pp_comma_list ~inner_metas:[ params_meta ] context (pp_pat context lookup))
        params;
      Format.fprintf fmt ")";
      pp_trailing context params_meta fmt;
      Format.fprintf fmt " ->@ %a@]" (pp_expr context lookup) body
  | Kernel.App (fn, args) ->
      Format.fprintf fmt "@[<hv 2>%a(%a" (pp_expr_atom context lookup) fn
        (pp_comma_list ~inner_metas:[ expr.meta ] context (pp_call_argument context lookup))
        args;
      Format.fprintf fmt ")@]"
  | Kernel.Let _ -> pp_block context lookup fmt expr
  | Kernel.Tuple items -> (
      match items with
      | [] ->
          Format.pp_print_char fmt '(';
          pp_inner context expr.meta fmt;
          Format.pp_print_char fmt ')'
      | [ item ] ->
          Format.fprintf fmt "@[<hv 2>(%a"
            (pp_comma_list ~singleton:true ~inner_metas:[ expr.meta ] context
               (pp_expr context lookup))
            [ item ];
          Format.fprintf fmt ")@]"
      | _ ->
          Format.fprintf fmt "@[<hv 2>(%a"
            (pp_comma_list ~inner_metas:[ expr.meta ] context (pp_expr context lookup))
            items;
          Format.fprintf fmt ")@]")
  | Kernel.Ann (subject, ty) ->
      Format.fprintf fmt "@[<hov 2>(%a" (pp_expr context lookup) subject;
      pp_following_keyword fmt (ends_in_line_comment context (pp_expr context lookup) subject) ":";
      Format.fprintf fmt "@ %a" (pp_ty context lookup) ty;
      pp_inner context expr.meta fmt;
      pp_closing fmt (ends_in_last_line_comment context (pp_ty context lookup) expr.meta [ ty ]) ")";
      Format.fprintf fmt "@]"
  | Kernel.Match (subject, clauses) -> pp_match context lookup expr.meta fmt subject clauses
  | Kernel.Handle { body; ret; ops } -> pp_handle context lookup expr.meta fmt body ret ops
  | Kernel.Quote payload -> pp_quote context lookup expr.meta fmt payload
  | Kernel.Unquote splice ->
      Format.fprintf fmt "unquote(%a" (pp_expr context lookup) splice;
      pp_inner context expr.meta fmt;
      pp_closing fmt
        (ends_in_last_line_comment context (pp_expr context lookup) expr.meta [ splice ])
        ")"

and if_branches = function
  | [
      { Kernel.cpat = { it = Kernel.PCon (_, []); meta = true_meta }; cbody = yes; _ };
      { Kernel.cpat = { it = Kernel.PCon (_, []); meta = false_meta }; cbody = no; _ };
    ]
    when Meta.surface_form true_meta = Some "if-true"
         && Meta.surface_form false_meta = Some "if-false" ->
      Some (yes, no)
  | _ -> None

and expression_ends_in_line_comment context lookup expression =
  ends_in_line_comment context (pp_expr context lookup) expression

and pp_if context lookup fmt condition yes no =
  let rec pp_else fmt expression =
    match (Meta.surface_form expression.Kernel.meta, expression.it) with
    | Some "if", Kernel.Match (condition, clauses) -> (
        match if_branches clauses with
        | Some (yes, no) ->
            Format.pp_print_string fmt "else ";
            pp_leading context expression.meta fmt;
            Format.fprintf fmt "@[<hov 2>if %a" (pp_expr context lookup) condition;
            pp_following_break fmt (expression_ends_in_line_comment context lookup condition) "then";
            Format.fprintf fmt "@ %a@]" (pp_expr context lookup) yes;
            if expression_ends_in_line_comment context lookup yes then
              Format.pp_force_newline fmt ();
            Format.fprintf fmt "@ %a" pp_else no;
            pp_trailing context expression.meta fmt
        | None -> Format.fprintf fmt "else %a" (pp_expr context lookup) expression)
    | _ -> Format.fprintf fmt "else %a" (pp_expr context lookup) expression
  in
  Format.fprintf fmt "@[<hv 0>@[<hov 2>if %a" (pp_expr context lookup) condition;
  pp_following_break fmt (expression_ends_in_line_comment context lookup condition) "then";
  Format.fprintf fmt "@ %a@]" (pp_expr context lookup) yes;
  if expression_ends_in_line_comment context lookup yes then Format.pp_force_newline fmt ();
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
  Format.fprintf fmt "@[<hv 2>[%a"
    (pp_comma_list ~inner_metas:[ meta; container_meta ] context (pp_expr context lookup))
    items;
  Format.fprintf fmt "]@]";
  pp_trailing context container_meta fmt

and pp_pipe context lookup meta fmt left fn args =
  let rhs_meta = Meta.surface_container "pipe-rhs" meta in
  let explicit_call =
    match Meta.surface_form rhs_meta with
    | Some ("pipe-call" | "pipe-named-call") -> true
    | Some _ | None -> false
  in
  let pp_operator fmt () =
    pp_following_break fmt (ends_in_line_comment context (pp_pipe_left context lookup) left) "|> ";
    pp_leading context rhs_meta fmt
  in
  match args with
  | [] when not explicit_call ->
      Format.fprintf fmt "@[<hov 2>%a%a%a" (pp_pipe_left context lookup) left pp_operator ()
        (pp_pipe_value context lookup) fn;
      pp_inner context rhs_meta fmt;
      pp_trailing context rhs_meta fmt;
      pp_inner context meta fmt;
      Format.fprintf fmt "@]"
  | _ ->
      Format.fprintf fmt "@[<hv 2>%a%a%a(%a" (pp_pipe_left context lookup) left pp_operator ()
        (pp_expr_atom context lookup) fn
        (pp_comma_list ~inner_metas:[ rhs_meta; meta ] context (pp_call_argument context lookup))
        args;
      Format.fprintf fmt ")";
      pp_trailing context rhs_meta fmt;
      Format.fprintf fmt "@]"

and pp_call_argument context lookup fmt (argument : Kernel.expr) =
  match Meta.surface_call_label argument.meta with
  | None -> pp_expr context lookup fmt argument
  | Some label ->
      let field_meta = Meta.surface_container "call-argument" argument.meta in
      pp_leading context field_meta fmt;
      Format.fprintf fmt "@[<hov 2>%a:@ %a@]" (pp_named Surface_name.Term) label
        (pp_expr context lookup) argument;
      pp_trailing context field_meta fmt

and pp_pipe_left context lookup fmt expr = pp_expr_atom context lookup fmt expr

and pp_pipe_value context lookup fmt expr =
  let block_meta = Meta.surface_container "block" expr.Kernel.meta in
  let paren_meta = Meta.surface_container "paren" expr.meta in
  if not (Meta.is_empty paren_meta) then pp_grouped context lookup paren_meta fmt expr
  else if not (Meta.is_empty block_meta) then pp_singleton_block context lookup block_meta fmt expr
  else pp_expr_atom context lookup fmt expr

and pp_grouped context lookup paren_meta fmt expr =
  pp_leading context paren_meta fmt;
  (* Only an inner group that owns comments keeps its own parentheses; comment-free nesting
     collapses to one pair as before. *)
  let inner = Meta.surface_container "paren" paren_meta in
  let expr =
    {
      expr with
      Kernel.meta =
        (if context.trivia && paren_chain_has_comments inner then
           Meta.with_surface_container "paren" inner expr.meta
         else Meta.without_surface_container "paren" expr.meta);
    }
  in
  Format.fprintf fmt "(@[<hov>%a" (pp_expr context lookup) expr;
  pp_inner context paren_meta fmt;
  if ends_in_last_line_comment context (pp_expr context lookup) paren_meta [ expr ] then
    Format.pp_force_newline fmt ();
  Format.fprintf fmt "@])";
  pp_trailing context paren_meta fmt

and pp_singleton_block context lookup block_meta fmt expr =
  pp_leading context block_meta fmt;
  let expr = { expr with Kernel.meta = Meta.without_surface_container "block" expr.meta } in
  Format.fprintf fmt "@[<v 2>{@,%a" (pp_expr context lookup) expr;
  pp_inner context block_meta fmt;
  pp_close_brace fmt
    (ends_in_line_comment context
       (fun fmt () ->
         pp_expr context lookup fmt expr;
         pp_inner context block_meta fmt)
       ());
  pp_trailing context block_meta fmt

and pp_expr_atom context lookup fmt expr =
  let paren_meta = Meta.surface_container "paren" expr.Kernel.meta in
  if not (Meta.is_empty paren_meta) then pp_grouped context lookup paren_meta fmt expr
  else if
    match (Meta.surface_form expr.meta, expr.it) with
    | Some "if", Kernel.Match (_, clauses) -> Option.is_some (if_branches clauses)
    | _ -> false
  then pp_parenthesized context lookup fmt expr
  else
    match expr.Kernel.it with
    | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.App _ | Kernel.Match _
    | Kernel.Tuple _ | Kernel.Let _ | Kernel.Handle _ | Kernel.Quote _ | Kernel.Unquote _
    | Kernel.Ann _ ->
        pp_expr context lookup fmt expr
    | Kernel.Lam _ -> pp_parenthesized context lookup fmt expr

and pp_parenthesized context lookup fmt expr =
  Format.fprintf fmt "(%a" (pp_expr context lookup) expr;
  pp_closing fmt (expression_ends_in_line_comment context lookup expr) ")"

and pp_sequence_item context lookup fmt (meta, isrec, binder, value) =
  pp_leading context meta fmt;
  match (isrec, binder.Kernel.it, value.Kernel.it) with
  | _ when Meta.surface_form meta = Some "try-bare" ->
      Format.fprintf fmt "@[<hov 2>try %a@]" (pp_expr context lookup) value;
      pp_trailing context meta fmt
  | _ when Meta.surface_form meta = Some "try" ->
      Format.fprintf fmt "@[<hov 2>let %a =@ try %a@]" (pp_pat context lookup) binder
        (pp_expr context lookup) value;
      pp_trailing context meta fmt
  | false, Kernel.PWild, _
    when not (Option.equal String.equal (Meta.surface_form meta) (Some "let")) ->
      pp_expr context lookup fmt value;
      pp_trailing context meta fmt
  | true, Kernel.PVar name, Kernel.Lam (params, body) ->
      let params_meta = Meta.surface_container "params" value.meta in
      Format.fprintf fmt "@[<hv 2>let rec %a" (pp_named Surface_name.Term) name;
      pp_leading context params_meta fmt;
      Format.fprintf fmt "(%a"
        (pp_comma_list ~inner_metas:[ params_meta ] context (pp_pat context lookup))
        params;
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
    match (current.Kernel.it, try_item current) with
    | Kernel.Let _, _ when Option.is_some (field_update_elaboration current) ->
        (List.rev acc, current)
    | Kernel.Let { isrec; binder; value; body }, _ ->
        collect ((current.Kernel.meta, isrec, binder, value) :: acc) body
    | _, Some (_, payload, subject, rest) ->
        collect ((current.Kernel.meta, false, payload, subject) :: acc) rest
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
  pp_close_brace fmt
    (ends_in_line_comment context
       (fun fmt () ->
         pp_expr context lookup fmt result;
         pp_inner context container_meta fmt)
       ());
  pp_trailing context container_meta fmt

and pp_match context lookup meta fmt subject clauses =
  let pp_clause fmt (clause : Kernel.clause) =
    pp_leading context clause.cmeta fmt;
    match clause.cbody.it with
    | _ when is_block_expr clause.cbody ->
        (* The arm's braces are the block's own, so its comments print inside them. *)
        let block_meta = Meta.surface_container "block" clause.cbody.meta in
        Format.fprintf fmt "@[<v 2>| %a -> {@," (pp_pat context lookup) clause.cpat;
        pp_leading context block_meta fmt;
        pp_sequence_contents context lookup fmt clause.cbody;
        if context.trivia then
          List.iter
            (fun comment -> Format.fprintf fmt "@,%s" comment)
            (Meta.comment_texts Meta.key_trivia_inner block_meta);
        Format.fprintf fmt "@]@,}";
        pp_trailing context clause.cmeta fmt
    | _ ->
        Format.fprintf fmt "@[<hov 2>| %a ->@ %a@]" (pp_pat context lookup) clause.cpat
          (pp_expr context lookup) clause.cbody;
        pp_trailing context clause.cmeta fmt
  in
  Format.fprintf fmt "@[<v 2>match %a {@,%a" (pp_expr context lookup) subject (pp_sep "" pp_clause)
    clauses;
  pp_inner context meta fmt;
  pp_close_brace fmt (ends_in_last_line_comment context pp_clause meta clauses)

and pp_arm_body context lookup fmt body =
  if is_block_expr body then pp_block context lookup fmt body else pp_expr context lookup fmt body

and pp_sequence_contents context lookup fmt expr =
  let rec collect acc current =
    match (current.Kernel.it, try_item current) with
    | Kernel.Let { isrec; binder; value; body }, _ ->
        collect ((current.Kernel.meta, isrec, binder, value) :: acc) body
    | _, Some (_, payload, subject, rest) ->
        collect ((current.Kernel.meta, false, payload, subject) :: acc) rest
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
    Format.fprintf fmt "@[<hv 2>| %a" (pp_gref lookup Surface_name.Op clause.ometa) clause.op;
    pp_leading context params_meta fmt;
    Format.fprintf fmt "(%a"
      (pp_comma_list ~inner_metas:[ params_meta ] context (pp_pat context lookup))
      clause.params;
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
     | _ when is_block_expr body ->
         Format.fprintf fmt " {@,%a@;<0 -2>} {" (pp_sequence_contents context lookup) body
     | _ -> Format.fprintf fmt " {@,%a@;<0 -2>} {" (pp_expr context lookup) body);
  Format.fprintf fmt "@,%a" pp_ret ret;
  List.iter (fun clause -> Format.fprintf fmt "@,%a" pp_op clause) ops;
  pp_inner context meta fmt;
  let last_clause fmt () =
    match List.rev ops with [] -> pp_ret fmt ret | last :: _ -> pp_op fmt last
  in
  pp_close_brace fmt (ends_in_last_line_comment context last_clause meta [ () ])

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
      pp_following_break fmt
        (ends_in_last_line_comment context (pp_expr context lookup) meta [ expr ])
        "}";
      Format.fprintf fmt "@]"
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

(* A multi-binding group prints as adjacent definitions only when reparsing recovers the same
   group: its names are distinct and it is strongly connected under the relation lowering uses to
   form definition components (free term names, see [Surface_lower.free_names]) together with
   internal [GroupRef] edges. Anything else keeps the [jqd { (defterm ...) }] escape. *)
let printable_term_group bindings =
  let count = List.length bindings in
  if count <= 1 then true
  else if
    List.length (List.sort_uniq String.compare (List.map (fun b -> b.Kernel.bname) bindings))
    <> count
  then false
  else
    let edges =
      Array.of_list
        (List.map
           (fun binding ->
             let free = Surface_lower.free_names binding.Kernel.value in
             let named =
               List.concat
                 (List.mapi
                    (fun index sibling ->
                      if Surface_lower.String_set.mem sibling.Kernel.bname free then [ index ]
                      else [])
                    bindings)
             in
             named @ group_refs_expr [] binding.Kernel.value
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
        (* A comment before the body forces a line break. In the shared [hv] box that break would
           also spread the parameters vertically, so the header then gets a box of its own and
           the body starts on the next line. Comment-free output keeps the single box. *)
        let body_commented = context.trivia && leading_comments body.meta <> [] in
        if body_commented then Format.fprintf fmt "@[<v 2>";
        Format.fprintf fmt "@[<hv 2>%a" (pp_named Surface_name.Term) binding.bname;
        pp_leading context params_meta fmt;
        Format.fprintf fmt "(%a"
          (pp_comma_list ~inner_metas:[ params_meta ] context (pp_callable_pat context lookup))
          params;
        Format.fprintf fmt ")";
        pp_trailing context params_meta fmt;
        if body_commented then
          Format.fprintf fmt "@]%a@,%a@]"
            (fun fmt () -> pp_following_keyword fmt (has_line_trailing context params_meta) "=")
            () (pp_expr context lookup) body
        else Format.fprintf fmt " =@ %a@]" (pp_expr context lookup) body
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
      Format.fprintf fmt "@[<v>@[<hov 2>%a :@ %a@]" (pp_named Surface_name.Term) binding.bname
        (pp_ty context lookup) ty;
      pp_trailing context signature_meta fmt;
      Format.fprintf fmt "@,%a@]" pp_definition ();
      pp_trailing context binding.bmeta fmt

let pp_field context lookup fmt (field : Kernel.field) =
  pp_leading context field.fmeta fmt;
  (match field.label with
  | None -> pp_ty context lookup fmt field.fty
  | Some label ->
      Format.fprintf fmt "@[<hov 2>%a:@ %a@]" (pp_named Surface_name.Term) label
        (pp_ty context lookup) field.fty);
  pp_trailing context field.fmeta fmt

let pp_constructor ?(leading = true) context lookup fmt (constructor : Kernel.conspec) =
  if leading then pp_leading context constructor.kmeta fmt;
  Format.fprintf fmt "@[<hv 2>";
  pp_named Surface_name.Con fmt constructor.con_name;
  if constructor.fields <> [] then
    if List.exists (fun field -> Option.is_some field.Kernel.label) constructor.fields then begin
      let params_meta = Meta.surface_container "params" constructor.kmeta in
      pp_leading context params_meta fmt;
      Format.fprintf fmt "(%a"
        (pp_comma_list ~inner_metas:[ params_meta ] context (pp_field context lookup))
        constructor.fields;
      Format.fprintf fmt ")"
    end
    else begin
      let types = List.map (fun (field : Kernel.field) -> field.fty) constructor.fields in
      (* a line break between positional fields would end the field list, so a field whose
         parenthesized type owns comments (which break lines inside its parentheses) is joined
         with plain spaces *)
      if context.trivia && List.exists type_owns_comments types then begin
        Format.pp_print_char fmt ' ';
        pp_joined ~starts_with_comment:type_starts_with_comment context (pp_ty_atom context lookup)
          fmt types
      end
      else begin
        Format.pp_print_space fmt ();
        pp_spaced context (pp_ty_atom context lookup) fmt types
      end
    end;
  Format.fprintf fmt "@]";
  pp_trailing context constructor.kmeta fmt

let mode_name = function Kernel.Once -> "once" | Kernel.Multi -> "multi"

let pp_operation ?inherited_mode context lookup fmt (operation : Kernel.opspec) =
  let params_meta = Meta.surface_container "params" operation.smeta in
  pp_leading context operation.smeta fmt;
  (match inherited_mode with
  | Some mode when mode = operation.op_mode -> ()
  | Some _ -> raise Bug_unsupported_surface_form
  | None -> Format.fprintf fmt "%s " (mode_name operation.op_mode));
  Format.fprintf fmt "@[<hv 2>%a :@ " (pp_named Surface_name.Op) operation.op_name;
  pp_leading context params_meta fmt;
  (* The signature box may already have broken after [:]. Padding the nested custom breaks keeps
     parameter types two columns inside [(], while [)] returns to the opening delimiter's column. *)
  Format.fprintf fmt "(%a"
    (pp_comma_list ~break_padding:"  " ~inner_metas:[ params_meta ] context
       (pp_callable_ty context lookup))
    operation.op_params;
  Format.fprintf fmt ")";
  pp_trailing context params_meta fmt;
  Format.fprintf fmt " ->@ %a@]" (pp_ty context lookup) operation.op_result;
  pp_trailing context operation.smeta fmt

let flat_type_decl_length lookup tname tvars constructors =
  let buffer = Buffer.create 128 in
  let formatter = Format.formatter_of_buffer buffer in
  Format.pp_set_margin formatter 1_000_000;
  Format.fprintf formatter "@[<h>type %a" (pp_named Surface_name.Type) tname;
  List.iter (fun name -> Format.fprintf formatter " %a" (pp_named Surface_name.Tvar) name) tvars;
  Format.fprintf formatter " =";
  List.iter
    (fun constructor ->
      Format.fprintf formatter " | %a"
        (pp_constructor ~leading:false canonical_context lookup)
        constructor)
    constructors;
  Format.fprintf formatter "@]";
  Format.pp_print_flush formatter ();
  Buffer.length buffer

let pp_decl context lookup fmt (decl : Kernel.decl) =
  pp_leading context decl.meta fmt;
  (match decl.it with
  | Kernel.DefTerm bindings ->
      if not (printable_term_group bindings) then raise Bug_unsupported_surface_form;
      Format.fprintf fmt "@[<v>%a@]" (pp_sep "" (pp_binding context lookup)) bindings
  | Kernel.DefType { tname; tvars; cons } ->
      (* A horizontal box never breaks, so an own-line comment, or a line comment followed by
         another constructor, requires the vertical layout. *)
      let needs_lines =
        context.trivia
        && (Meta.comment_texts Meta.key_trivia_inner decl.meta <> []
           || List.exists (fun constructor -> leading_comments constructor.Kernel.kmeta <> []) cons
           ||
           match List.rev cons with
           | [] -> false
           | _ :: earlier ->
               List.exists
                 (ends_in_line_comment context (pp_constructor ~leading:false context lookup))
                 earlier)
      in
      let vertical =
        needs_lines || flat_type_decl_length lookup tname tvars cons > Format.pp_get_margin fmt ()
      in
      Format.fprintf fmt
        (if vertical then "@[<v 2>type %a" else "@[<h>type %a")
        (pp_named Surface_name.Type) tname;
      List.iter (fun name -> Format.fprintf fmt " %a" (pp_named Surface_name.Tvar) name) tvars;
      Format.fprintf fmt (if vertical then " =@," else " = ");
      List.iteri
        (fun index constructor ->
          if index > 0 then Format.fprintf fmt (if vertical then "@," else " ");
          pp_leading context constructor.Kernel.kmeta fmt;
          Format.fprintf fmt "| %a" (pp_constructor ~leading:false context lookup) constructor)
        cons;
      pp_inner context decl.meta fmt;
      Format.fprintf fmt "@]"
  | Kernel.DefEffect { ename; evars; ops } ->
      let uniform_mode =
        match ops with
        | [] -> None
        | first :: rest ->
            if List.for_all (fun operation -> operation.Kernel.op_mode = first.op_mode) rest then
              Some first.op_mode
            else None
      in
      (match uniform_mode with
      | Some mode ->
          Format.fprintf fmt "@[<v 2>%s effect %a" (mode_name mode) (pp_named Surface_name.Effect)
            ename
      | None -> Format.fprintf fmt "@[<v 2>effect %a" (pp_named Surface_name.Effect) ename);
      List.iter (fun name -> Format.fprintf fmt " %a" (pp_named Surface_name.Tvar) name) evars;
      Format.fprintf fmt " where {@,%a"
        (pp_sep "" (pp_operation ?inherited_mode:uniform_mode context lookup))
        ops;
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

let render_at_margin ~margin pp value =
  let buffer = Buffer.create 128 in
  let fmt = Format.formatter_of_buffer buffer in
  Format.pp_set_margin fmt margin;
  pp fmt value;
  Format.pp_print_flush fmt ();
  Buffer.contents buffer

let max_line_length text =
  String.split_on_char '\n' text
  |> List.fold_left (fun longest line -> max longest (String.length line)) 0

(* [Format] conservatively breaks a complete group whose last byte lands exactly at the margin, so
   first try one internal byte beyond the requested width and retain that rendering only when its
   physical lines still fit. Otherwise render at the requested margin. Never search narrower
   margins: [Format] may satisfy them by clamping structural indentation, making a one-byte edit
   move a type continuation back to column zero. Indivisible tokens, comments, declaration headers,
   and quantified prefixes therefore retain their shortest valid rendering when they cannot fit. *)
let render ~width pp value =
  let requested_margin = max 2 width in
  let upper = render_at_margin ~margin:(requested_margin + 1) pp value in
  if max_line_length upper <= width then upper
  else render_at_margin ~margin:requested_margin pp value

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
  Format.fprintf fmt "@[<hv 2>| %a(%a) resume %a ->@ %a@]"
    (pp_gref lookup Surface_name.Op clause.ometa)
    clause.op
    (pp_comma_list context (pp_pat context lookup))
    clause.params pp_resume clause.resume (pp_arm_body context lookup) clause.obody

let fragment_error form =
  Error
    [
      Diag.error ~domain:Surface ~code:"E1203"
        ~summary:"Kernel form has no self-contained surface fragment"
        ~cause:(Printf.sprintf "`%s` is not a self-contained surface fragment." form.Form.head)
        ~next_step:"Render this form in its enclosing declaration or expression context."
        ~contrast:None ();
    ]

(** [print_fragment] renders a kernel form even when it is an interior pattern, type, row, or
    auxiliary product. It is intended for semantic diff and diagnostics; context-ambiguous [group]
    forms return E1203 rather than guessing. *)
let print_fragment ?(lookup : lookup option) ?(width = default_width) (form : Form.t) :
    (string, Diag.t list) result =
  let rendered pp value =
    match render ~width pp value with
    | text -> Ok text
    | exception Bug_unsupported_surface_form -> fragment_error form
  in
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

(* Bootstrap [;] comments inside a raw [jqd { ... }] escape, skipping string literals. *)
let raw_comments source =
  let length = String.length source in
  let rec scan index in_string acc =
    if index >= length then List.rev acc
    else
      match source.[index] with
      | '\\' when in_string -> scan (index + 2) true acc
      | '"' -> scan (index + 1) (not in_string) acc
      | ';' when not in_string ->
          let stop = Option.value ~default:length (String.index_from_opt source index '\n') in
          scan stop false (("raw", String.trim (String.sub source index (stop - index))) :: acc)
      | _ -> scan (index + 1) in_string acc
  in
  scan 0 false []

(* The comments of [text] as a sorted multiset of (kind, trimmed text). Order is not compared:
   lowering legitimately moves declarations (dependency order) together with their comments. *)
let comment_texts ~file text =
  List.concat_map
    (fun (located : Surface_lex.located) ->
      match located.token with
      | Surface_lex.Comment comment -> [ ("line", String.trim comment) ]
      | Surface_lex.DocComment comment -> [ ("doc", String.trim comment) ]
      | Surface_lex.RawCandidate { source; _ } -> raw_comments source
      | _ -> [])
    (Surface_lex.lex_recover ~file text).tokens
  |> List.sort compare

(** [check_reparses ?source ~file text] returns [Ok text] when [text] is a strict surface file and,
    given the [source] it was formatted from, keeps every comment of [source] (line, doc and raw
    bootstrap comments, as a multiset: declarations may move with their comments); otherwise E1204.
    It is the formatter's last line of defense: [jac fmt] never prints or writes formatted text that
    its own parser rejects or that loses or alters a comment, so a printer bug surfaces as a nonzero
    exit and a diagnostic instead of broken code or silent data loss. *)
let check_reparses ?source ~file text : (string, Diag.t list) result =
  let refuse cause =
    Error
      [
        Diag.error ~domain:Surface ~code:"E1204"
          ~summary:"The formatter produced text that does not parse" ~cause
          ~next_step:"Report this formatter bug with the input file; keep the source as written."
          ~contrast:None ();
      ]
  in
  match Surface_parse.strict_file (Surface_parse.recover_string ~file text) with
  | Error diagnostics ->
      refuse
        (Printf.sprintf
           "Formatting `%s` succeeded, but reparsing the result reported %d syntax diagnostic(s). \
            The output was discarded and the file was not changed."
           file (List.length diagnostics))
  | Ok _ -> (
      match source with
      | Some source when comment_texts ~file source <> comment_texts ~file text ->
          refuse
            (Printf.sprintf
               "Formatting `%s` would drop or alter a comment. The output was discarded and the \
                file was not changed."
               file)
      | Some _ | None -> Ok text)

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
