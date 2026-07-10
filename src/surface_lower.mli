(** Local lowering from recoverable surface syntax to the fixed kernel. *)

module String_set : Set.S with type elt = string

exception Bug_scc_schedule of string
(** Raised only when the exact-SCC condensation graph violates an internal scheduling invariant.
    Valid surface input cannot trigger this exception. *)

val lower_pat : Surface_ast.pat -> (Kernel.pat, Diag.t list) result
(** Lower an irrefutable SS.7 pattern. Refutable patterns and recovery holes are diagnostics. *)

val lower_ty : Surface_ast.ty -> (Kernel.ty, Diag.t list) result
(** Lower a surface type without resolving named type or effect references. Type holes are
    diagnostics. *)

val lower_expr : Surface_ast.expr -> (Kernel.expr, Diag.t list) result
(** Lower an expression in the implemented surface slice. Recovery holes, malformed local bindings,
    and later-slice forms are diagnostics. *)

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
