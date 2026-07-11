(** Hole-tolerant, diagnostic-only checking for recovered `.jac` trees. *)

type report = {
  diagnostics : Diag.t list;
  signatures : (string * Types.scheme) list;
      (** Successfully checked names from independent analysis islands, in analysis order. *)
}

val analyze : names:Resolve.names -> Check.ctx -> Surface_ast.recovered -> report
(** [analyze ~names ctx recovered] checks a recovered surface tree for editor feedback. Parser holes
    behave as fresh types with no effect contribution, diagnostics are source ordered, and checking
    continues across independent top-level islands. Every call uses isolated checker caches and
    mutable analysis state. Successfully checked term islands are visible to later islands through
    analysis-local names and schemes; declarations are not installed in the store. Type/effect
    declarations are checked in isolation, but later islands cannot refer to them until a strict
    path installs them. The API does not return a lowered tree or make holes valid for strict
    compile/run paths. *)
