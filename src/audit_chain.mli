(** Versioned HASH_V0 chaining for canonical AuditEntry forms. *)

type record
(** One validated [audit-chain-v1] record. Its digest commits to the predecessor and the canonical
    bytes of its embedded [audit-entry-v1] form. *)

val genesis : Hash.t
(** The fixed predecessor for an empty v1 chain. *)

val digest : previous:Hash.t -> Form.t -> (Hash.t, Diag.t list) result
(** [digest ~previous entry] validates [entry] against the released v1 AuditEntry wire schema and
    hashes its existing {!Printer.print_compact} bytes with [previous]. Malformed entries return
    E1302. *)

val append : previous:Hash.t -> Form.t -> (record, Diag.t list) result
(** [append ~previous entry] constructs the next record without performing I/O. Malformed entries
    return E1302. *)

val head : record -> Hash.t
(** [head record] is the record's committed HASH_V0 digest. *)

val render : record -> string
(** [render record] returns its one-line canonical carrier without a trailing LF. *)

val verify_string : file:string -> expected_head:Hash.t -> string -> (Hash.t, Diag.t list) result
(** [verify_string ~file ~expected_head bytes] strictly verifies a canonical v1 chain. Every record
    must occupy one LF-terminated canonical line. Linkage, embedded entry schema, stored digests,
    and the published [expected_head] are checked in order. Empty input verifies only against
    {!genesis}. All failures are diagnostics (E1301--E1305); malformed input never raises. *)

val verify_file : file:string -> expected_head:Hash.t -> (Hash.t, Diag.t list) result
(** [verify_file ~file ~expected_head] reads and verifies [file]. I/O failures return E1306. *)

val read_entry_file : file:string -> (Form.t, Diag.t list) result
(** [read_entry_file ~file] performs the same bounded, change-detecting read used for chain logs,
    then parses exactly one AuditEntry form. Expected I/O races and failures return E1306; syntax
    diagnostics come from the bootstrap reader. *)

val append_file : file:string -> previous:Hash.t -> Form.t -> (Hash.t, Diag.t list) result
(** [append_file ~file ~previous entry] first verifies the existing file against the caller's
    published [previous] head, then appends exactly one canonical record plus LF and returns the new
    publishable head. A nonblocking advisory whole-file lock covers bounded reading, verification,
    pathname-identity revalidation, and writing through the same open file description. The
    operation remains intended for a single cooperating writer; I/O or concurrent-change failures
    return E1306 and no exception escapes. *)
