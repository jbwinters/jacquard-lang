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
      | [ item ] -> Format.fprintf fmt "(@[<hov>%a,@])" (pp_pat lookup) item
      | _ -> Format.fprintf fmt "(@[<hov>%a@])" (pp_sep "," (pp_pat lookup)) items)
  | Kernel.PAs (name, inner) ->
      Format.fprintf fmt "@[<hov>%a as %a@]" (pp_pat lookup) inner (pp_named Surface_name.Term) name

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

and pp_expr lookup fmt (expr : Kernel.expr) =
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
  | Kernel.Match _ | Kernel.Handle _ | Kernel.Quote _ | Kernel.Unquote _ ->
      raise Bug_unsupported_surface_form

and pp_expr_atom lookup fmt expr =
  match expr.Kernel.it with
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.App _ ->
      pp_expr lookup fmt expr
  | _ -> Format.fprintf fmt "(%a)" (pp_expr lookup) expr

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

(** [print_top ?lookup ?width top] renders one validated kernel top-level item without a trailing
    newline. [lookup] supplies display names for hash references whose metadata lacks one. *)
let print_top ?(lookup : lookup option) ?(width = default_width) (top : Kernel.top) :
    (string, Diag.t list) result =
  match top with
  | Kernel.Expr expr -> (
      match render ~width (pp_expr lookup) expr with
      | text -> Ok text
      | exception Bug_unsupported_surface_form -> Ok (raw_top top))
  | Kernel.Decl _ -> Ok (raw_top top)

(** [print_file] renders a complete canonical surface file with one trailing newline. *)
let print_file ?(lookup : lookup option) ?(width = default_width) (tops : Kernel.top list) :
    (string, Diag.t list) result =
  let rec loop acc = function
    | [] ->
        let body = String.concat "\n\n" (List.rev acc) in
        Ok (if String.equal body "" then "" else body ^ "\n")
    | top :: rest -> (
        match print_top ?lookup ~width top with
        | Ok text -> loop (text :: acc) rest
        | Error ds -> Error ds)
  in
  loop [] tops
