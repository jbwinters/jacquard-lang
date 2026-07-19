(** Runtime errors (plan W2.2): what a well-formed, resolved program can still do wrong at run time.
    The checker (M2) will rule most of these out statically; the interpreter must trap them all the
    same. *)

type t =
  | Match_failure of string
      (** no clause matched; carries the printed scrutinee (plan W2.2 done-when) *)
  | Unhandled of { effect_ : string; op : string }
      (** an operation reached the root with no handler and no grant — the capability story at
          runtime (spec §5.1 rule 7) *)
  | Arity of string  (** wrong number of arguments in an uncurried application *)
  | Arithmetic of string  (** builtin arithmetic failure, e.g. division by zero *)
  | Io of string  (** world-effect IO failure (fs read/write, clock) surfaced by a root handler *)
  | Observe_at_root
      (** [observe] reached the root sampling handler (D7 default: a defect; observation needs an
          inference driver) *)
  | Once_resumed_twice
      (** a once resumption was applied after its captured instance had already been resumed *)
  | Invalid_task_handle of string
      (** a malformed, foreign-run, or cross-scope Task handle reached a runtime boundary *)
  | Scheduler_error of string
      (** deterministic structured-scheduler refusal or invariant diagnostic *)
  | Type_error of string  (** applying a non-function, spliced non-code, and similar *)
  | Unresolved of string  (** an unresolved name or dangling hash reached evaluation *)
  | Eval_error of string  (** the gated [eval] op rejected its payload at the boundary *)
  | Diagnostic of Diag.t
      (** a subsystem diagnostic that must retain its domain, code, and remediation when it crosses
          the evaluator's single-error channel *)

(** [to_string error] renders compact technical cause text for embedding in another failure. *)
let to_string = function
  | Match_failure scrutinee -> Printf.sprintf "no clause matched the value %s" scrutinee
  | Io msg -> Printf.sprintf "io error: %s" msg
  | Observe_at_root ->
      "observe reached the sampling root handler; observation requires an inference driver (use \
       jacquard infer)"
  | Once_resumed_twice -> "a once continuation may be resumed at most once per captured instance"
  | Invalid_task_handle message -> message
  | Scheduler_error message -> message
  | Unhandled { effect_; op } ->
      Printf.sprintf "unhandled effect %s: operation `%s` reached the root without a handler"
        effect_ op
  | Arity msg -> "arity mismatch: " ^ msg
  | Arithmetic msg -> "arithmetic error: " ^ msg
  | Type_error msg -> "type error: " ^ msg
  | Unresolved msg -> "unresolved reference: " ^ msg
  | Eval_error msg -> "eval rejected its argument: " ^ msg
  | Diagnostic diagnostic -> Diag.to_cause_string diagnostic

(** [to_diag error] projects a runtime failure into the canonical structured diagnostic contract.
    Embedded subsystem diagnostics retain their existing identity. Only ordinary runtime failures
    with historically assigned public codes carry one; the rest remain deliberately code-less
    instead of inventing new release identities. Secret-bearing values must already be redacted by
    {!Value.show} before they enter a runtime error. *)
let to_diag error =
  let make ?code ~domain ~summary ~next_step () =
    Diag.error ?code ~domain ~summary ~cause:(to_string error) ~next_step ~contrast:None ()
  in
  match error with
  | Diagnostic diagnostic -> diagnostic
  | Match_failure _ ->
      make ~domain:Runtime ~summary:"No match clause accepted the value"
        ~next_step:"Add a clause for this value or a wildcard default." ()
  | Unhandled _ ->
      make ~domain:Runtime ~summary:"An effect reached the root without a handler"
        ~next_step:"Grant the effect at the root or handle it inside the program." ()
  | Arity _ ->
      make ~domain:Runtime ~summary:"Runtime call arity does not agree"
        ~next_step:"Pass exactly the number of arguments required by the callable." ()
  | Arithmetic _ ->
      make ~domain:Runtime ~summary:"Arithmetic operation failed"
        ~next_step:"Correct the arithmetic inputs and run the program again." ()
  | Io _ ->
      make ~domain:Runtime ~summary:"World-effect I/O failed"
        ~next_step:"Correct the path, permissions, or external resource and try again." ()
  | Observe_at_root ->
      make ~domain:Runtime ~code:"E0904" ~summary:"Observation is invalid at the sampling root"
        ~next_step:"Move the observation under an inference handler." ()
  | Once_resumed_twice ->
      make ~domain:Runtime ~code:"E0906" ~summary:"A once continuation was resumed more than once"
        ~next_step:"Resume each captured once continuation at most once." ()
  | Invalid_task_handle _ ->
      make ~domain:Concurrency ~code:"E0907" ~summary:"A scoped task or channel handle is invalid"
        ~next_step:"Use the handle only inside the exact async.scope that created it." ()
  | Scheduler_error _ ->
      make ~domain:Concurrency ~code:"E0908" ~summary:"Deterministic scheduler operation failed"
        ~next_step:"Correct the schedule state or operation and try again." ()
  | Type_error _ ->
      make ~domain:Runtime ~summary:"Runtime value has the wrong type"
        ~next_step:"Pass a value of the type required by this operation." ()
  | Unresolved _ ->
      make ~domain:Runtime ~summary:"Runtime reference is unresolved"
        ~next_step:"Resolve every name and hash before evaluation." ()
  | Eval_error _ ->
      make ~domain:Runtime ~summary:"Eval rejected its code value"
        ~next_step:"Pass validated closed code to eval." ()

let pp fmt t = Format.pp_print_string fmt (to_string t)
