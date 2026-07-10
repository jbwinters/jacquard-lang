(** Local lowering from recoverable surface syntax to the fixed kernel. *)

module String_set : Set.S with type elt = string

exception Bug_scc_schedule of string
(** Raised only when the exact-SCC condensation graph violates an internal scheduling invariant.
    Valid surface input cannot trigger this exception. *)

val lower_pat : Surface_ast.pat -> (Kernel.pat, Diag.t list) result
(** Lower any complete surface pattern without resolving named constructors. Recovery holes are
    diagnostics; contextual irrefutability restrictions are enforced by expression lowering. *)

val lower_ty : Surface_ast.ty -> (Kernel.ty, Diag.t list) result
(** Lower a surface type without resolving named type or effect references. Type holes are
    diagnostics. *)

val lower_expr : Surface_ast.expr -> (Kernel.expr, Diag.t list) result
(** Lower an expression in the implemented surface slice. Handlers preserve named/hashed operation
    intent and quote bodies become pre-resolution kernel forms with depth-aware unquote splices.
    Unquote outside quote is E0204. Match clauses accept every kernel pattern form; lambda
    parameters and nonrecursive let binders retain E0205/E0206 irrefutability checks. Recovery
    holes, malformed local bindings, and later-slice forms are diagnostics. *)

val free_names : Kernel.expr -> String_set.t
(** Return unresolved term names read by an expression, excluding pattern/let/lambda binders and
    quoted data. Only live unquotes contribute names; malformed raw quote splices are ignored
    because validated kernel expressions are the contract. *)

val lower_top : Surface_ast.top -> (Kernel.top, Diag.t list) result
(** Lower one non-signature top. A definition is a singleton SCC; a signature requires [lower_tops].
*)

val lower_tops : Surface_ast.top list -> (Kernel.top list, Diag.t list) result
(** Lower a strictly parsed file, attaching signatures and partitioning uninterrupted definition
    runs into exact dependency-first SCCs. Duplicate names fail with E0303 before graph
    construction; malformed signature context and recovery holes are diagnostics. *)

type file = { tops : Kernel.top list; meta : Meta.t }

val lower_file : Surface_ast.file -> (file, Diag.t list) result
(** Lower a strict file and retain its file-level trivia anchor. *)
