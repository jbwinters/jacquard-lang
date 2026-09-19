(** RF.1 frontend services: the one program-preparation pipeline shared by the CLI commands, the
    host worker, and later project and editor consumers.

    This is an internal library seam, not a stable public embedding ABI: its signatures move with
    the commands that use them. Every service returns diagnostics instead of printing them; Cmdliner
    parsing, presentation, and exit codes stay in the command modules.

    Ownership. A store opened by {!open_session} belongs to one session. A checker made by
    {!make_checker} reads its store lazily, so it sees every later installation into that store and
    must not be used with any other store. {!check} owns a fresh scratch store and its checker for
    the duration of one call and never touches a caller's store; only {!install_declarations} (and
    the callers' own [walk] with installation) write to a persistent store. *)

(** {1 Source carriers} *)

type syntax =
  | Auto
  | Bootstrap
  | Surface
      (** Requested source syntax. [Auto] selects the surface syntax for [.jac] files and the
          bootstrap reader otherwise. *)

val syntax_for_file : syntax -> string -> syntax
(** [syntax_for_file syntax file] resolves [Auto] for [file]; the result is never [Auto]. *)

type parsed_top =
  | Bootstrap_form of Form.t
  | Surface_top of Kernel.top  (** A top-level item before kernel validation and resolution. *)

val parse_tops :
  syntax:syntax ->
  names:Resolve.names ->
  file:string ->
  string ->
  (parsed_top list * Diag.t list, Diag.t list) result
(** [parse_tops ~syntax ~names ~file source] strictly parses [source]. Surface input is recovered,
    required to be free of damage, linted against [names], and lowered; the lint warnings are
    returned beside the tops. A malformed file fails with the parser's diagnostics: recovery
    analysis belongs to {!check} and never produces tops. *)

val validate_parsed_top : parsed_top -> (Kernel.top, Diag.t list) result
(** [validate_parsed_top top] validates a bootstrap form as a kernel top; lowered surface tops are
    already kernel tops. *)

(** {1 Sessions and checkers} *)

val open_session : prelude_dir:string -> root:string -> (Store.t * Eval.ctx, Diag.t list) result
(** [open_session ~prelude_dir ~root] opens (creating when absent) the store at [root], loads the
    prelude from [prelude_dir] into it, and wires the builtins into a fresh evaluation context.
    Store, prelude, and builtin failures are returned in that order. *)

val make_checker : ?require_builtins:bool -> Store.t -> (Check.ctx, Diag.t list) result
(** [make_checker store] creates a checker over [store] and registers the prelude's builtin
    signatures. A store without builtin signatures is accepted (marker bodies type as code) unless
    [require_builtins] is [true], in which case that failure is returned. *)

(** {1 The shared per-top pipeline} *)

type installation =
  | Install  (** A refused declaration fails the walk. *)
  | Install_best_effort
      (** A refused declaration is skipped; later tops resolve without it ([hash]). *)

val walk :
  ?origin:string ->
  ?install:installation ->
  ?on_parsed:(Diag.t list -> unit) ->
  ?before_resolve:(Kernel.top -> (unit, Diag.t list) result) ->
  ?on_resolved:(Kernel.top -> Diag.t list -> (unit, Diag.t list) result) ->
  ?on_installed:(Kernel.decl -> Canon.decl_hashes -> (unit, Diag.t list) result) ->
  syntax:syntax ->
  file:string ->
  Store.t ->
  string ->
  (unit, Diag.t list) result
(** [walk ~syntax ~file store source] parses [source] ({!parse_tops}, passing the lint warnings to
    [on_parsed]) and then, top by top and in source order: validates it, calls [before_resolve] with
    the unresolved top, resolves it against the current names of [store], calls [on_resolved] with
    the resolved top and the resolver warnings, and installs a declaration in [store] (stamped with
    [origin]) before calling [on_installed] with its identities. Later tops therefore see exactly
    the declarations installed before them. The first failure stops the walk; declarations installed
    before it stay installed (see {!install_declarations}). *)

val walk_tops :
  ?origin:string ->
  ?install:installation ->
  ?before_resolve:(Kernel.top -> (unit, Diag.t list) result) ->
  ?on_resolved:(Kernel.top -> Diag.t list -> (unit, Diag.t list) result) ->
  ?on_installed:(Kernel.decl -> Canon.decl_hashes -> (unit, Diag.t list) result) ->
  Store.t ->
  Kernel.top list ->
  (unit, Diag.t list) result
(** [walk_tops store tops] is {!walk} over already validated tops. *)

val resolve_source_tops :
  syntax:syntax ->
  Store.t ->
  file:string ->
  string ->
  (Kernel.top list * Diag.t list, Diag.t list) result
(** [resolve_source_tops ~syntax store ~file source] walks the whole source, installing each
    declaration in [store], and returns the resolved tops with the surface lint warnings followed by
    the resolver warnings. Any failure is returned without a partial result. *)

val install_declarations :
  ?origin:string ->
  ?on_parsed:(Diag.t list -> unit) ->
  expression_refusal:Diag.t ->
  syntax:syntax ->
  Store.t ->
  file:string ->
  string ->
  (unit, Diag.t list) result
(** [install_declarations ~expression_refusal ~syntax store ~file source] installs a
    declarations-only source into a persistent [store] as one transaction. A top-level expression
    anywhere in the file is refused with [expression_refusal] before anything is installed
    ([on_parsed] then receives the lint warnings of the installing pass); a parse, resolution, or
    store failure part-way through (or an exception, which is re-raised) restores the store's index,
    name file, and object set to their state before the call. Declarations are not type-checked. *)

(** {1 Read-only checking and the sealed checked artifact} *)

module Checked : sig
  type t
  (** The sealed result of one successful strict {!check}. Only {!check} constructs it, so an
      artifact always describes a whole source that parsed, resolved, and checked in order against
      the prelude it records; recovery analysis never produces one. *)

  type top = {
    resolved : Kernel.top;  (** The resolved kernel top. *)
    identity : Canon.decl_hashes option;  (** A declaration's canonical identities. *)
    signatures : (string * string) list;
        (** Each introduced name with its scheme as rendered when it was checked. *)
    effects : Hash.t list;  (** An expression's inferred effect row; [[]] for declarations. *)
    call_abis : (Hash.t * string option list) list;
        (** The declaration's explicit surface call-label companions. *)
    warnings : Diag.t list;  (** Resolver then checker warnings for this top. *)
  }

  val file : t -> string

  val source_digest : t -> Hash.t
  (** HASH_V0 of the exact source bytes. *)

  val prelude : t -> (string * string) list option
  (** The prelude identity ({!Store.prelude_manifest}) the source was checked against. *)

  val tops : t -> top list
  (** The checked tops in source order. *)

  val dependencies : t -> Hash.t list
  (** Sorted identities the source references but does not itself introduce. *)

  type stale =
    | Prelude_changed  (** The store's prelude identity differs from the artifact's. *)
    | Missing_dependency of Hash.t  (** A referenced identity is absent from the store. *)
    | Missing_declaration of Hash.t
        (** A declaration of the source, possibly superseded later in it, is absent. *)
    | Rebound of { name : string; expected : Hash.t; found : Hash.t option }
        (** A name the source introduced does not resolve, for its kind, to the checked identity. *)
    | Call_abi_changed of Hash.t
        (** A callable's call-label companion differs from (or is absent beside) the checked one;
            labels are not part of identity, so equal hashes can carry different labels. *)
    | Unreadable_store of Diag.t list  (** The store's persisted state cannot be reopened. *)

  val verify : t -> Store.t -> (unit, stale) result
  (** [verify artifact store] succeeds only when the artifact's facts hold in [store]: the same
      prelude identity, every dependency and every declaration of the source (superseded ones
      included) present, each (name, kind) the source bound last still bound to the checked
      identity, and each introduced callable carrying exactly the checked call-label companion.
      Scheduler-private members count as bound through their hidden binding. [verify] reopens the
      store's root and judges its persisted state, so a handle that missed another handle's writes
      cannot vouch for an artifact. The first failure in that order is returned. A consumer must
      verify before trusting an artifact against any store, since stores outlive the session that
      checked the source. *)
end

type recovery = {
  diagnostics : Diag.t list;  (** Findings in source order. *)
  signatures : (string * string) list;
      (** Names checked by independent analysis islands, with rendered schemes. *)
}
(** The editor recovery report for a damaged surface source ({!Surface_check.analyze}). *)

type outcome =
  | Checked of Checked.t
  | Recovered of recovery  (** The surface source is damaged; recovery never seals an artifact. *)

val check :
  ?origin:string ->
  ?on_parsed:(Diag.t list -> unit) ->
  ?on_resolved:(Kernel.top -> Diag.t list -> unit) ->
  ?on_checked:(Check.ctx -> Kernel.top -> Check.top_sig -> (unit, Diag.t list) result) ->
  prelude_dir:string ->
  root:string ->
  syntax:syntax ->
  file:string ->
  string ->
  (outcome, Diag.t list) result
(** [check ~prelude_dir ~root ~syntax ~file source] opens a scratch session at [root], which must
    not exist or be an empty directory ([Invalid_argument] otherwise, so a persistent store can
    never be mutated by checking), and strictly checks [source] top by top in source order: each top
    is resolved ([on_resolved] receives the resolver warnings before checking), checked, and passed
    to [on_checked] with the session's checker, which is borrowed for the duration of the callback;
    declarations are installed in the scratch store only after [on_checked] accepts them. A damaged
    surface source returns the recovery report instead. The first failure is returned. *)
