(** Affine usage checking for the built-in {!Types.TResume} callable. *)

type resolved_callable = {
  resolved_key : string;
  resolved_source : string;
  resolved_params : Kernel.pat list;
  resolved_body : Kernel.expr;
  resolved_recursive : bool;
}
(** A stored lambda that can receive a Resume token. Recursive callables are exposed for a pointed
    rejection because their consumption count is not bounded by the local syntax walk.
    [resolved_key] identifies memoized summaries; [resolved_source] is an honest durable logical
    source label for canonical stored-helper witnesses, not an original author-source path. *)

type clause_context =
  | Ordinary
  | Immediately_applied_transformer
      (** How the enclosing handler result is used. [Immediately_applied_transformer] is a trusted
          checker witness: the [Handle] is the direct function child of one [App], every argument is
          a syntactic value, and therefore a direct clause lambda is constructed and eliminated
          exactly once. It opens only that outer lambda; every captured-Resume call result must then
          be the direct function child of one nested application, so a result carrying a later Once
          token cannot be bound or duplicated. Captures under any further lambda remain escapes. *)

val is_immediate_transformer_argument : Kernel.expr -> bool
(** [is_immediate_transformer_argument expression] recognizes the closed syntactic-value boundary
    used for both the outer handler application and the nested elimination of a Resume-produced
    answer. It accepts literals, lookups, lambdas, inert quotes, tuples and constructor trees of
    values, plus annotations around those forms. *)

val check_clause :
  ?resolve_term:(Hash.t -> resolved_callable option) ->
  ?context:clause_context ->
  resume:string ->
  Kernel.expr ->
  (unit, Diag.t list) result
(** [check_clause ~resolve_term ~resume body] accepts exactly those once-operation clauses that
    drop, call, or transfer [resume] at most once on every possible execution path. Match arms are
    exclusive, and aligned sequential matches over the same immutable variable or resolved reference
    preserve their arm correlation. Transfers are allowed only to a local or resolved lambda
    parameter whose body passes the same check. With [context=Immediately_applied_transformer], a
    direct outer clause lambda is treated as called exactly once and its body receives the same
    affine budget; each Resume call result must be immediately eliminated as the function child of
    one application whose arguments satisfy {!is_immediate_transformer_argument}. E0816 reports two
    consumption spans; E0817 reports an escape/capture site. *)

val check_escapes :
  ?resolve_term:(Hash.t -> resolved_callable option) ->
  ?context:clause_context ->
  resume:string ->
  Kernel.expr ->
  (unit, Diag.t list) result
(** [check_escapes] performs the same capture, storage, and transfer checks as [check_clause] but
    defers duplicate-consumption errors. The checker uses it before ordinary inference so E0817
    remains purpose-built while malformed applications retain their E0801/E0803 diagnostics. In
    particular, a Resume argument beyond a known local or stored lambda's arity is deferred to
    inference; [check_clause] retains an E0817 fallback when called independently. The optional
    [context] has the same trusted-caller contract as {!check_clause}. *)
