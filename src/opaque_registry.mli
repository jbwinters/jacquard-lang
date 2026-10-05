(** The constructors of opaque types (TYPE.1) that any store in this process has indexed, so that
    user-facing renderers ({!Value.display}) and typed observations can redact their values without
    a store in hand. Opacity is part of a constructor's identity, so the answer never depends on
    which store indexed it. *)

val register : Hash.t -> string -> unit
(** [register con type_name] records that [con] constructs the opaque type [type_name]. *)

val type_of : Hash.t -> string option
(** [type_of con] is the opaque type [con] constructs, if this process has indexed it. *)
