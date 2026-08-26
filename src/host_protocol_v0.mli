(** Strict bounded codecs for the provisional [jacquard-host-v0] process carrier.

    This module implements transport framing, structural JSON checks, limit negotiation, the
    selected shutdown envelope, the frozen first-order type/value descriptors, and preflight for one
    exact checked invocation. It does not evaluate code, dispatch host operations, or expose a
    runnable worker. *)

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
