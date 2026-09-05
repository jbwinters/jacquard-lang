(** Strict bounded codecs for the provisional [jacquard-host-v0] process carrier.

    This module implements transport framing, structural JSON checks, limit negotiation, the
    selected shutdown envelope, the frozen first-order type/value descriptors, and preflight for one
    exact checked invocation. Session implements serial request/response and terminal accounting.
    The module does not evaluate code, dispatch host operations, or expose a runnable worker. *)

val protocol : string
(** The one protocol version accepted by this codec. *)

val carrier : string
(** The provisional four-byte big-endian length-prefixed JSON carrier name. *)

type limits = {
  max_frame_bytes : int;
  max_json_depth : int;
  max_value_nodes : int;
  max_text_bytes : int;
  max_collection_items : int;
  max_arguments : int;
  max_effects : int;
  max_operations : int;
  max_effect_requests : int;
  max_diagnostics : int;
  max_diagnostic_bytes : int;
  max_host_message_bytes : int;
  max_stderr_bytes : int;
}
(** Frozen hard or host-selected ceilings. Every selected field is positive and no greater than the
    corresponding {!hard_limits} field. *)

val hard_limits : limits
(** The fixed maxima advertised before selection. *)

type boundary_budget
(** Mutable aggregate node accounting for all boundary types and values in one frame. A caller
    creates one budget after limit selection, shares it across every descriptor in that frame, and
    discards it after either success or the first diagnostic. *)

val create_boundary_budget : limits -> boundary_budget
(** [create_boundary_budget limits] starts a zero-node budget using [limits]. Invalid nonpositive
    selected ceilings fail as E1602 when a codec first observes them. *)

val decode_boundary_type : budget:boundary_budget -> Yojson.Safe.t -> (Types.ty, Diag.t list) result
(** [decode_boundary_type ~budget json] accepts exactly the recursive nominal/tuple type subset,
    canonical HASH_V0 identities, and the selected structural/node/collection ceilings. Malformed
    shapes return E1601, exceeded limits E1602, and unsupported type variants E1604. *)

val encode_boundary_type : budget:boundary_budget -> Types.ty -> (Yojson.Safe.t, Diag.t list) result
(** [encode_boundary_type ~budget ty] emits the deterministic descriptor for a normalized
    boundary-safe Core type. Unresolved variables, arrows, resumptions, variadic arrows, and exact
    thunks return E1604; malformed internal text or exceeded limits retain E1601/E1602. *)

val decode_boundary_value :
  budget:boundary_budget ->
  constructor_info:(Hash.t -> (string * int, Diag.t list) result) ->
  Yojson.Safe.t ->
  (Value.t, Diag.t list) result
(** [decode_boundary_value ~budget ~constructor_info json] accepts exactly the frozen
    Int/Real/Text/Hash/tuple/saturated-constructor subset. [constructor_info] resolves each exact
    constructor identity to its store-owned display name and declared arity; its diagnostic is
    propagated, and an arity mismatch returns E1604. Field-type validation deliberately remains in
    invoke preflight. Malformed shapes return E1601, exceeded limits E1602, and unsupported value
    variants E1604. *)

val encode_boundary_value : budget:boundary_budget -> Value.t -> (Yojson.Safe.t, Diag.t list) result
(** [encode_boundary_value ~budget value] emits the deterministic lossless descriptor for a
    boundary-safe Core value. Constructor display names never cross the wire. Opaque, callable, or
    run-owned values return E1604; malformed UTF-8 and exceeded limits retain E1601/E1602. *)

type operation_binding = {
  effect_identity : Hash.t;
  operation : Hash.t;
  parameters : Types.ty list;
  result : Types.ty;
}
(** One exact, checked, once-mode operation admitted by an invocation's closed host registry. *)

type invocation = {
  invocation_id : string;
  callable : Hash.t;
  parameters : Types.ty list;
  effects : Hash.t list;
  result : Types.ty;
  arguments : Value.t list;
  operations : operation_binding list;
}
(** Immutable preflight output for the later serial worker. Types, effects, values, and operation
    contracts come from the checked store rather than mutable display names. *)

val parse_invoke :
  limits:limits -> checker:Check.ctx -> Yojson.Safe.t -> (invocation, Diag.t list) result
(** [parse_invoke ~limits ~checker json] validates the exact v0 invoke envelope, fixed invocation
    ID, public stored term target and complete reachable closure, closed monomorphic first-order
    arrow, structurally identical interface, typed positional values, exact effect grants, and
    sorted unique once-operation registry. It returns E1600-E1605 or E1608 according to the frozen
    fail-fast order and never evaluates the target or calls an adapter. A registry may be partial or
    empty; reaching an omitted operation is a later worker concern. *)

val limits_to_yojson : limits -> Yojson.Safe.t
(** [limits_to_yojson limits] emits every limit field once in deterministic lexical order. *)

val core_hello : unit -> Yojson.Safe.t
(** [core_hello ()] is the exact first Core envelope under the hard limits. *)

val parse_host_select : Yojson.Safe.t -> (limits, Diag.t list) result
(** [parse_host_select json] validates the exact selection envelope, version, positive
    component-wise bounds, and capacity for the mandatory smallest terminal frames. Shape failures
    return E1601, an unknown version returns E1600, state errors return E1608, and limit failures
    return E1602. *)

val parse_shutdown : limits:limits -> Yojson.Safe.t -> (unit, Diag.t list) result
(** [parse_shutdown ~limits json] accepts only the exact selected pre-invocation shutdown envelope
    under [limits]. Unknown versions return E1600, envelope-shape failures E1601, another message
    kind E1608, and a selected structural-limit violation E1602. *)

val shutdown_ack : unit -> Yojson.Safe.t
(** [shutdown_ack ()] is the exact terminal acknowledgement for a selected pre-invocation shutdown.
*)

val encode_frame_bytes : limits:limits -> Yojson.Safe.t -> (string, Diag.t list) result
(** [encode_frame_bytes ~limits json] returns one complete u32-big-endian frame. The value must be a
    structurally valid JSON object within [limits]; invalid shape returns E1601 and an exceeded
    limit returns E1602. *)

val decode_frame_bytes : limits:limits -> string -> (Yojson.Safe.t, Diag.t list) result
(** [decode_frame_bytes ~limits bytes] decodes exactly one complete frame and rejects extra carrier
    bytes. Truncated framing returns E1611; malformed framing/JSON returns E1601; an exceeded limit
    returns E1602. *)

val read_frame : limits:limits -> in_channel -> (Yojson.Safe.t, Diag.t list) result
(** [read_frame ~limits input] reads exactly one frame from [input]. EOF or I/O loss before the
    frame is complete returns E1611; malformed data and exceeded limits retain E1601/E1602. *)

val write_frame : limits:limits -> out_channel -> Yojson.Safe.t -> (unit, Diag.t list) result
(** [write_frame ~limits output json] writes and flushes one complete frame. Encoding failures
    retain E1601/E1602; an output or flush failure returns E1611. *)

(** Serial invocation accounting without evaluator continuations or carrier I/O. Keep the
    checker/store stable for a session's lifetime. The caller owns writes, flushes, continuation
    resume/drop, descriptor release, and carrier loss. Actions are committed when returned and must
    never be retried. *)
module Session : sig
  type t
  type action = Request of Yojson.Safe.t | Resume of Value.t | Finished of Yojson.Safe.t

  val start : limits:limits -> checker:Check.ctx -> Yojson.Safe.t -> (t, Diag.t list) result
  (** Validate selected limits and full invoke preflight, then reserve a bounded error outcome
      before accepting the invocation. Returns the preflight diagnostics or E1602 if terminal
      evidence cannot fit; never evaluates. *)

  val call : t -> Hash.t * Value.t list
  (** The checked target and positional arguments for the caller's isolated evaluator. *)

  val request : t -> operation:Hash.t -> arguments:Value.t list -> (action, Diag.t list) result
  (** In the running state, validate the configured operation and actual values, reserve terminal
      capacity, and return one [Request]. Missing operations finish with E1606, mismatched values
      with E1603/E1604, limits with E1602. A second request while waiting finishes with E1608. No
      refused request enters evidence. The caller retains exactly one continuation. *)

  val respond : t -> Yojson.Safe.t -> (action, Diag.t list) result
  (** Consume one matching response slot. [Resume] carries a type-checked value exactly once; the
      caller may then resume its captured continuation. Failure/cancellation returns [Finished] with
      the frozen terminal mapping; the caller must drop the continuation. Rejected messages finish
      with E1608 (E1602 for a selected limit) and are not accepted observations. *)

  val finish : t -> Value.t -> (action, Diag.t list) result
  (** Validate the actual invocation result and return one bounded [Finished]. Wrong
      types/unsupported values yield E1603/E1604, capacity failures E1602, and attempting to finish
      while waiting E1608. Result and evidence share the frame's boundary-node budget. *)

  val abort : t -> Diag.t list -> (action, Diag.t list) result
  (** End a live invocation with its structured runtime diagnostics. Empty or oversized diagnostics
      become the fixed E1602 fallback. Carrier loss can prevent writing this action; do not
      fabricate a delivered terminal. *)

  val fatal : limits:limits -> Diag.t list -> (Yojson.Safe.t, Diag.t list) result
  (** Encode a pre-invocation fatal with bounded diagnostics. Oversized or empty diagnostics become
      E1602; returns Error if even the fallback cannot fit. Use negotiated limits after selection
      and hard limits before selection. *)

  (** All state-changing calls after [Finished] return Error E1608, never a second terminal. Every
      returned frame obeys selected structural and byte limits. If full diagnostics cannot fit, a
      fixed E1602 diagnostic replaces them while retaining accepted observations and terminal
      classification. *)
end
