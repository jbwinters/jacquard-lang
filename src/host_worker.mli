(** Opt-in serial [stdio-u32-json-v0] worker for the frozen [jacquard-host-v0] protocol.

    The worker drives exactly one host-selected invocation over an already opened local store: it
    writes [core_hello], accepts one [host_select], then either acknowledges a pre-invocation
    [shutdown] or evaluates one checked target while exchanging typed root operations with the
    trusted host in lockstep. It installs no root handlers and never reloads the prelude; every root
    operation that the checked target reaches is either served through the closed configured
    registry or refused with a structured outcome. Ordinary [jac run], native artifacts, and the
    interpreted scheduler do not use this module. *)

type exit_status =
  | Terminal_written
      (** One complete [outcome], [fatal], or [shutdown_ack] frame was flushed; exit 0. *)
  | Protocol_failure  (** No bounded terminal frame fits the negotiated limits; exit 64. *)
  | Internal_failure  (** A Core invariant failed after preflight; exit 70. *)
  | Carrier_lost
      (** Standard input or output was lost. A best-effort E1611 frame may still have been flushed,
          but the host must classify any outstanding outside action itself; exit 74. *)

val exit_code : exit_status -> int
(** [exit_code status] maps the worker result onto the process exit statuses frozen in
    [spec/host-protocol-v0.md] section 3. *)

type prepared
(** A store with wired builtin implementations and a checker seeded with builtin signatures. *)

val prepare : Store.t -> (prepared, Diag.t list) result
(** [prepare store] wires builtins and creates the checker over an already opened store without
    reloading the prelude. A store that was never populated with the prelude fails closed with the
    prelude's own E0702 diagnostics. *)

val serve :
  prepared -> input:in_channel -> output:out_channel -> operator:out_channel -> exit_status
(** [serve prepared ~input ~output ~operator] runs one complete worker lifetime. Frames are read
    from [input] and written, one at a time and fully flushed, to [output]. [operator] receives
    bounded human diagnostics limited to the hard and then the selected [max_stderr_bytes]; it is
    never a protocol or evidence channel. The function closes none of the three channels and retains
    no continuation, session, or descriptor after it returns. Every terminal action is committed
    when written and is never retried. [SIGPIPE] is ignored for the dynamic extent of the call so a
    host that closes its read end yields [Carrier_lost] instead of a fatal signal; the previous
    disposition is restored afterwards. Bytes that could not be written stay in the caller's channel
    buffer, so a process boundary must discard them rather than flush them at exit. Exceptions are
    contained and reported as [Internal_failure] except a stack overflow inside evaluation, which
    becomes a bounded E0003 outcome. *)
