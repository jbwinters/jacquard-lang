(** MODEL.1 model documents and dependency records (docs/designs/model-dependencies.md).

    A model document ([jacquard-model-v1]) names a source, closed assumptions, text inputs, and
    results: an exported entry term applied to declared arguments under a driver and a fuel budget.
    Each result has a canonical dependency record ([jacquard-model-dependency-v1]) naming exactly
    what produces it, and its key is a domain-separated HASH_V0 of that record. This module parses
    and validates documents and computes records; evaluation and caching belong to
    [jacquard model eval]. *)

val format_version : int

(** {1 Documents} *)

type driver =
  | Run  (** the entry's row must be pure apart from grants *)
  | Enumerate of { max_branches : int }  (** exact posterior; [dist] is handled by the driver *)
  | Lw of { seed : int; samples : int }
      (** likelihood weighting; [dist] is handled by the driver *)

type argument =
  | Named of string  (** an assumption, an input, or an exported term *)
  | Inline of string  (** a numeric literal, an unnamed assumption *)

type result_decl = {
  r_name : string;
  r_entry : string;  (** the exported entry term *)
  r_arguments : argument list;
  r_driver : driver;
  r_fuel : int;  (** the fuel-v1 budget of the whole invocation, always finite *)
  r_line : int;
}

type t = {
  source : string;  (** the source path, relative to the document's directory *)
  policy : string option;  (** an [observation-policy-v1] file, relative to the document *)
  assumptions : (string * string * int) list;  (** name, expression source, line *)
  inputs : (string * string * int) list;  (** name, path, line; read as UTF-8 [Text] *)
  results : result_decl list;  (** in document order *)
}

val parse : file:string -> string -> (t, Diag.t list) result
(** [parse ~file text] reads a document strictly: the [jacquard-model format=1] header first, one
    [source] line, at most one [policy] line, unique names across assumptions, inputs, and results,
    and canonical numbers. Blank lines and lines starting with [#] are ignored. Refused with E1800
    (malformed) or E1801 (a repeated name). *)

val read : string -> (t, Diag.t list) result
(** [read file] reads a regular file (E1804 when it cannot be read) and {!parse}s it. *)

(** {1 Dependency records} *)

type argument_identity =
  | Assumption of Hash.t  (** the HASH_V0 of the assumption's resolved kernel expression *)
  | Input of Hash.t  (** the HASH_V0 of the input's bytes *)
  | Term of { term : Hash.t; signature : Hash.t }

type dependency = {
  entry : Hash.t;
  signature : Hash.t;  (** of the entry's name-independent checked scheme *)
  labels : string option list option;  (** the entry's call labels; [None] when positional *)
  prelude : string;  (** the prelude identity as hex, or ["none"] *)
  core : string;
  driver : driver;
  fuel : int;
  policy : Hash.t;  (** the [observation-policy-v1] identity *)
  arguments : argument_identity list;
}

val serialize_dependency : dependency -> string
(** The canonical [jacquard-model-dependency-v1] bytes. *)

val parse_dependency : string -> (dependency, string) result
(** [parse_dependency bytes] accepts exactly canonical bytes ([serialize_dependency] of the result
    is [bytes]); anything else is refused with a reason. *)

val key : dependency -> Hash.t
(** HASH_V0 of ["jacquard-model-dependency-v1"], a NUL byte, and the canonical record. *)

val default_policy : Observation_policy.t
(** The policy of a document without a [policy] line: the result is compared, no operation is
    observed, and a field may hold 1 MiB. *)

(** {1 Resolving a document against its source} *)

type resolved = {
  decl : result_decl;
  dependency : dependency;
  application : Kernel.expr;
      (** the entry applied to its arguments, inputs as their text, ready to evaluate *)
  world : Hash.t list;
      (** effects the entry's row requires beyond what the driver handles: they need a root grant,
          and such a result is never cached *)
}

type prepared = {
  artifact : Frontend.Checked.t;
  store : Store.t;  (** the checked source's scratch store *)
  checker : Check.ctx;
  policy : Observation_policy.t;
  resolved : resolved list;  (** in document order *)
}

val prepare :
  prelude_dir:string -> root:string -> file:string -> t -> (prepared, Diag.t list) result
(** [prepare ~prelude_dir ~root ~file doc] checks the source into a scratch store at [root] (which
    must not exist or be empty), reads every input and the policy once, resolves and checks every
    assumption as closed literal data, and checks each result's application at the entry's types.
    Paths are relative to [file]'s directory. Refused, before anything runs: E1802 (an unknown name,
    a result used as an argument, or a name that is both declared and an exported term), E1803 (an
    assumption that is not closed literal data), E1804 (a missing, oversized, or malformed file),
    E1805 (an entry that is not an exported term, or an application that does not check). *)
