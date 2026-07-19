(** Offline verification for additive [governance-run-bundle-v1] evidence. *)

type report = {
  head : Hash.t;
  entries : int;
  calls : int;
  policies : int;
  assessments : int;
  proposals : int;
  consents : int;
  transformed_calls : int;
}
(** Counts from one fully linked bundle. [head] is the independently carried and reconstructed Audit
    chain head. The report makes no claim about action execution or rollback. *)

val verify_form : store:Store.t -> file:string -> Form.t -> (report, Diag.t list) result
(** [verify_form ~store ~file bundle] verifies one exact [governance-run-bundle-v1] form. It
    resolves each effect-qualified operation against [store]; recomputes unchanged Governance v0
    Call, BoundPolicy, Assessment, and Proposal identities; verifies the embedded Audit v2 hash
    chain; links Evaluated/Consented/Completed entries to unique artifacts; and checks explicit
    parent-call lineage. Failures are stable E1500--E1507 diagnostics with artifact or entry
    indexes. It does not infer whether an action ran from a missing completion. *)

val verify_string : store:Store.t -> file:string -> string -> (report, Diag.t list) result
(** [verify_string ~store ~file bytes] accepts exactly one compact canonical bundle form followed by
    one LF. Malformed, noncanonical, or unsupported input returns E1500. *)

val verify_file : store:Store.t -> file:string -> (report, Diag.t list) result
(** [verify_file ~store ~file] performs a bounded, change-detecting read and then calls
    {!verify_string}. Expected I/O failures and races return E1500; no exception escapes. *)
