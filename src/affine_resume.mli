(** Affine usage checking for the built-in {!Types.TResume} callable. *)

type resolved_callable = {
  resolved_params : Kernel.pat list;
  resolved_body : Kernel.expr;
  resolved_recursive : bool;
}
(** A stored lambda that can receive a Resume token. Recursive callables are exposed for a pointed
    rejection because their consumption count is not bounded by the local syntax walk. *)

val check_clause :
  ?resolve_term:(Hash.t -> resolved_callable option) ->
  resume:string ->
  Kernel.expr ->
  (unit, Diag.t list) result
(** [check_clause ~resolve_term ~resume body] accepts exactly those once-operation clauses that
    drop, call, or transfer [resume] at most once on every possible execution path. Match arms are
    exclusive. Transfers are allowed only to a local or resolved lambda parameter whose body passes
    the same check. E0816 reports two consumption spans; E0817 reports an escape/capture site. *)
