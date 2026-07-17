(** Filesystem boundary for explicit canonical bootstrap exports. *)

type read_error =
  | Stdin
  | Not_regular
  | Read_failure of string
      (** Stable input failure categories: stdin, a non-regular opened descriptor, or a described
          open/stat/read/close failure. *)

val read_regular_file : string -> (string, read_error) result
(** [read_regular_file path] opens [path] once in nonblocking mode, checks that same descriptor with
    [fstat], and reads it to EOF. It never follows a separate stat/read path and returns failures
    instead of raising. *)

type write_error =
  | Collision
  | Atomic_failure of string
      (** [Collision] means the destination existed and temporary cleanup succeeded.
          [Atomic_failure] describes publication, sync, rollback, or cleanup failure. *)

val write_atomic_exclusive : path:string -> string -> (unit, write_error) result
(** [write_atomic_exclusive ~path contents] exclusively publishes fully synced [contents], syncs the
    parent directory after publication and temporary cleanup, and never reports success when cleanup
    fails. It does not replace an existing destination. *)

module For_test : sig
  type fault_point =
    | Parent_sync_after_link
    | Temp_cleanup
    | Parent_sync_after_cleanup
    | Destination_rollback
    | Temp_rollback
    | Parent_sync_after_rollback

  val read_regular_file : after_open:(unit -> unit) -> string -> (string, read_error) result
  (** Descriptor-stability seam used to replace an input path after it has been opened. *)

  val write_atomic_exclusive :
    fault:(fault_point -> unit) -> path:string -> string -> (unit, write_error) result
  (** Fault-injection seam for publication, directory-sync, and cleanup tests. *)
end
