(** Recoverable `.jac` syntax before local lowering to {!Kernel}.

    Surface-only forms live here so the 27-form kernel and canonical serializer do not grow sugar.
    Every node carries metadata for spans, comments, docs, and provenance. [Hole] nodes are parser
    recovery artifacts: strict parsing rejects a file containing one, and hashing never receives
    them. *)

type 'a node = { it : 'a; meta : Meta.t }
type literal = Kernel.lit
type name = string
type gref = Named of name | Hashed of Hash.t

type expr = expr_node node

and expr_node =
  | Lit of literal
  | Name of name
  | HashRef of Hash.t * Kernel.refkind
  | GroupRef of int
  | Call of expr * expr list
  | Fn of pat list * expr
  | Tuple of expr list
  | List of expr list
  | Block of block_item list
  | Match of expr * clause list
  | If of expr * expr * expr
  | Pipe of expr * expr
  | Handle of expr * ret_clause * op_clause list
  | Quote of quote_body
  | Unquote of expr
  | Ann of expr * ty
  | Hole of int

and block_item =
  | Let of { recursive : bool; binder : pat; params : pat list; value : expr; meta : Meta.t }
  | Expr of expr

and clause = { cpattern : pat; cbody : expr; cmeta : Meta.t }
and ret_clause = { rbinder : pat; rbody : expr; rmeta : Meta.t }

and op_clause = {
  operation : gref;
  oparams : pat list;
  oresume : name;
  obody : expr;
  ometa : Meta.t;
}

and quote_body = Surface of expr | Raw of Form.t
and pat = pat_node node

and pat_node =
  | PWild
  | PBind of name
  | PLit of literal
  | PCon of gref * pat list
  | PTuple of pat list
  | PAs of pat * name
  | PHole of int

and ty = ty_node node

and ty_node =
  | TyName of name
  | TyVar of name
  | TyHash of Hash.t
  | TyApp of ty * ty list
  | TyArrow of ty list * row * ty
  | TyTuple of ty list
  | TyForall of name list * name list * ty
  | TyHole of int

and row = { effects : gref list; tail : name option; row_hole : int option; row_meta : Meta.t }

type field = { label : name option; ty : ty; meta : Meta.t }
type constructor = { name : name; fields : field list; meta : Meta.t }
type operation = { name : name; params : ty list; result : ty; meta : Meta.t }

type top = top_node node

and top_node =
  | Signature of name * ty
  | Definition of { name : name; equation : bool; params : pat list; value : expr }
  | TypeDecl of { name : name; vars : name list; constructors : constructor list }
  | EffectDecl of { name : name; vars : name list; operations : operation list }
  | TopExpr of expr
  | RawTop of Form.t
  | TopHole of int

type file = { tops : top list; meta : Meta.t }
(** A strict file retains the file-level trivia anchor without retaining the full source string. *)

type recovered = { items : top list; diagnostics : Diag.t list; meta : Meta.t; source : string }
(** A recovery result retains the complete original bytes, with an intentional O(source-size) memory
    cost, for lossless damaged-source replay. [meta] is the file-level trivia anchor used when no
    top-level node can own leading or EOF trivia. *)

let node ?(meta = Meta.empty) it = { it; meta }

(** [has_holes_top top] is true when parser recovery left an explicit hole or synthetic delimiter
    marker in [top]. Strict source entry points reject such trees before lowering, resolution,
    checking, or hashing. *)
let rec has_holes_top (top : top) =
  Option.is_some (Meta.surface_hole top.meta)
  ||
  match top.it with
  | Signature (_, ty) -> has_holes_ty ty
  | Definition { params; value; _ } -> List.exists has_holes_pat params || has_holes_expr value
  | TypeDecl { constructors; _ } ->
      List.exists
        (fun constructor -> List.exists (fun field -> has_holes_ty field.ty) constructor.fields)
        constructors
  | EffectDecl { operations; _ } ->
      List.exists
        (fun operation ->
          List.exists has_holes_ty operation.params || has_holes_ty operation.result)
        operations
  | TopExpr expr -> has_holes_expr expr
  | RawTop _ -> false
  | TopHole _ -> true

and has_holes_expr (expr : expr) =
  Option.is_some (Meta.surface_hole expr.meta)
  ||
  match expr.it with
  | Lit _ | Name _ | HashRef _ | GroupRef _ -> false
  | Call (fn, args) -> has_holes_expr fn || List.exists has_holes_expr args
  | Fn (params, body) -> List.exists has_holes_pat params || has_holes_expr body
  | Tuple items | List items -> List.exists has_holes_expr items
  | Block items -> List.exists has_holes_block_item items
  | Match (subject, clauses) ->
      has_holes_expr subject
      || List.exists
           (fun clause -> has_holes_pat clause.cpattern || has_holes_expr clause.cbody)
           clauses
  | If (cond, yes, no) -> has_holes_expr cond || has_holes_expr yes || has_holes_expr no
  | Pipe (left, right) -> has_holes_expr left || has_holes_expr right
  | Handle (body, ret, ops) ->
      has_holes_expr body || has_holes_pat ret.rbinder || has_holes_expr ret.rbody
      || List.exists (fun op -> List.exists has_holes_pat op.oparams || has_holes_expr op.obody) ops
  | Quote (Surface body) -> has_holes_expr body
  | Quote (Raw _) -> false
  | Unquote body -> has_holes_expr body
  | Ann (subject, ty) -> has_holes_expr subject || has_holes_ty ty
  | Hole _ -> true

and has_holes_block_item = function
  | Let { binder; params; value; _ } ->
      has_holes_pat binder || List.exists has_holes_pat params || has_holes_expr value
  | Expr expr -> has_holes_expr expr

and has_holes_pat (pat : pat) =
  Option.is_some (Meta.surface_hole pat.meta)
  ||
  match pat.it with
  | PWild | PBind _ | PLit _ -> false
  | PCon (_, args) | PTuple args -> List.exists has_holes_pat args
  | PAs (inner, _) -> has_holes_pat inner
  | PHole _ -> true

and has_holes_ty (ty : ty) =
  Option.is_some (Meta.surface_hole ty.meta)
  ||
  match ty.it with
  | TyName _ | TyVar _ | TyHash _ -> false
  | TyApp (head, args) -> has_holes_ty head || List.exists has_holes_ty args
  | TyArrow (params, row, result) ->
      Option.is_some row.row_hole || List.exists has_holes_ty params || has_holes_ty result
  | TyTuple items -> List.exists has_holes_ty items
  | TyForall (_, _, body) -> has_holes_ty body
  | TyHole _ -> true
