(** Strict type-and-effect checking plus an isolated editor-recovery service. *)

type ctx
(** Mutable checker state over one store. Its inference stacks and scheme caches are sealed. *)

exception Err of Diag.t
(** Internal checker short-circuit raised by scheme lookup helpers when their documented lookup or
    checking contract fails. Top-level checking APIs return diagnostics instead. *)

val make_ctx : Store.t -> (ctx, Diag.t list) result
(** [make_ctx store] resolves required primitive types and creates an empty checker cache. Missing
    or malformed primitive declarations are returned as diagnostics. *)

val store : ctx -> Store.t
(** [store ctx] returns the backing declaration store. *)

type primitive_types = {
  int_type : Hash.t;
  real_type : Hash.t;
  text_type : Hash.t;
  hash_type : Hash.t;
}
(** Exact store identities for the scalar values that can cross a first-order host boundary. *)

val primitive_types : ctx -> primitive_types
(** [primitive_types ctx] returns the primitive identities captured when [ctx] was created. The
    result is immutable and does not consult the mutable store name index. *)

val register_builtin_signatures : ctx -> (Hash.t * Types.scheme) list -> unit
(** [register_builtin_signatures ctx signatures] installs trusted native-term schemes, replacing
    entries at duplicate hashes. *)

val tier_applications : ctx -> (Types.row * Tier.app_kind) list
(** [tier_applications ctx] returns application classifications accumulated by strict checks. *)

val tier_operations : ctx -> (Hash.t * Tier.discipline) list
(** [tier_operations ctx] returns operation disciplines accumulated by strict checks. *)

val name_of : ctx -> Hash.t -> string
(** [name_of ctx hash] returns the store display name, falling back to hexadecimal when unnamed. *)

val show_scheme : ctx -> Types.scheme -> string
(** [show_scheme ctx scheme] renders a deterministic surface signature using store names. *)

val is_frozen_async_spawn : ctx -> Hash.t -> bool
(** [is_frozen_async_spawn ctx operation] is true only for the exact pinned SC.4 [async.spawn]
    identity whose complete resolved Async declaration matches all four frozen operations, modes,
    type-variable links, Task identities, and self-effect row. Missing or near-match declarations
    return false. The recognized operation's inferred callable row shares its child thunk row, so
    every higher-order transport preserves the child-effect charge. *)

val con_scheme : ctx -> ?meta:Meta.t -> Hash.t -> Types.scheme
(** [con_scheme ctx hash] returns a constructor scheme. It raises [Err] when [hash] is missing, has
    the wrong role, or its declaration is malformed. *)

val term_scheme : ctx -> ?meta:Meta.t -> Hash.t -> Types.scheme
(** [term_scheme ctx hash] returns or computes a term scheme. It raises [Err] for unresolved,
    wrong-kind, cyclic, or ill-typed declarations. *)

type top_sig = {
  names : (string * Types.scheme) list;
  row : Types.row option;
  warnings : Diag.t list;
}
(** Signatures, optional expression effect row, and non-fatal diagnostics from one checked top.
    W0801 covers redundant clauses; surface-authored positional term/operation calls with an
    applicable explicit companion label may additionally produce review warnings W1206-W1207. *)

val check_top : ctx -> Kernel.top -> (top_sig, Diag.t list) result
(** [check_top ctx top] strictly checks resolved kernel input. Recovery markers fail with E1202;
    resolution, typing, effects, and exhaustiveness failures are returned as diagnostics. *)

type recovery_session
(** Isolated mutable checker state used only for editor recovery analysis. *)

val start_recovery : ctx -> recovery_session
(** [start_recovery base] clones mutable checker state and all schemes. Later recovery checks cannot
    mutate [base] or install declarations in its store. *)

val check_recovery_top :
  identity:string -> recovery_session -> Kernel.top -> (top_sig, Diag.t list) result
(** [check_recovery_top ~identity session top] checks one projected recovery island. [identity] must
    be unique within [session]; failures are returned and no declaration is persisted. *)

val force_term : ctx -> Hash.t -> (Types.scheme, Diag.t list) result
(** [force_term ctx hash] computes a cached term scheme on demand, returning lookup/type failures.
*)

val force_constructor : ctx -> Hash.t -> (Types.scheme, Diag.t list) result
(** [force_constructor ctx hash] returns the constructor scheme or a checker diagnostic when the
    public hash is absent, has another role, or its declaration is malformed. *)

type operation_contract = { effect_identity : Hash.t; mode : Kernel.op_mode; scheme : Types.scheme }
(** Checked store metadata for one exact public operation identity. *)

val force_operation : ctx -> Hash.t -> (operation_contract, Diag.t list) result
(** [force_operation ctx hash] resolves the operation's owning effect, declared continuation mode,
    and checked callable scheme. Missing, hidden, wrong-role, or malformed declarations return
    checker diagnostics. *)

val show_row : ctx -> Types.row -> string
(** [show_row ctx row] renders every resolved identity in deterministic name/hash order. Distinct
    identities with the same declaration name are disambiguated by full hash rather than collapsed.
    This compact renderer is for signatures; authority review metadata is provided by
    {!Effect_registry}. *)

val manifest_errors :
  ctx -> ?grantable:string list -> granted:Hash.t list -> Types.row -> Diag.t list
(** [manifest_errors ctx ~granted row] reports effects required by [row] but not granted or handled.
    [grantable] controls remediation hints; the function does not mutate checker state. *)

val checker_codes : (string * string) list
(** Stable checker diagnostic code catalog used by documentation and corpus coverage tests. *)
