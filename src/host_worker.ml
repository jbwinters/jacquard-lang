(* HB.2c: the opt-in serial process carrier over Host_protocol_v0.Session. *)

module Host = Host_protocol_v0
module Session = Host.Session

type exit_status = Terminal_written | Protocol_failure | Internal_failure | Carrier_lost

let exit_code = function
  | Terminal_written -> 0
  | Protocol_failure -> 64
  | Internal_failure -> 70
  | Carrier_lost -> 74

type prepared = { ctx : Eval.ctx; checker : Check.ctx }

let prepare store =
  let ( let* ) = Result.bind in
  let ctx = Eval.make_ctx store in
  let* () = Prelude.wire_builtins ctx in
  Eval.set_coverage_tracking ctx false;
  let* checker = Check.make_ctx store in
  let* signatures = Prelude.builtin_signatures store in
  Check.register_builtin_signatures checker signatures;
  Ok { ctx; checker }

(* --- bounded operator output --- *)

type operator = { channel : out_channel; mutable remaining : int; mutable truncated : bool }

let truncation_marker = "\n[jacquard host worker: operator output truncated]\n"

(* The largest prefix length no greater than [limit] that ends on a UTF-8 scalar boundary. *)
let utf8_prefix text limit =
  let length = String.length text in
  let cut = ref (if limit < length then limit else length) in
  while !cut > 0 && !cut < length && Char.code text.[!cut] land 0xC0 = 0x80 do
    decr cut
  done;
  !cut

let note operator text =
  if (not operator.truncated) && operator.remaining > 0 then
    let text = text ^ "\n" in
    let length = String.length text in
    try
      if length <= operator.remaining then begin
        output_string operator.channel text;
        flush operator.channel;
        operator.remaining <- operator.remaining - length
      end
      else begin
        operator.truncated <- true;
        let marker_length = String.length truncation_marker in
        let budget =
          if operator.remaining > marker_length then operator.remaining - marker_length
          else operator.remaining
        in
        let cut = utf8_prefix text budget in
        output_string operator.channel (String.sub text 0 cut);
        if cut + marker_length <= operator.remaining then
          output_string operator.channel truncation_marker;
        flush operator.channel;
        operator.remaining <- 0
      end
    with Sys_error _ -> operator.remaining <- 0

(* --- diagnostics owned by the worker --- *)

let has_code code diagnostics = List.exists (fun d -> Diag.code d = Some code) diagnostics
let is_carrier_loss diagnostics = has_code "E1611" diagnostics

let invalid_response diagnostics =
  if has_code "E1602" diagnostics then diagnostics
  else
    [
      Diag.error ~domain:Process ~code:"E1608" ~summary:"The host response frame is invalid"
        ~cause:
          "The current response slot received a malformed or unreadable frame instead of exactly \
           one effect_ok, effect_failure, or cancel message."
        ~next_step:
          "Send one bounded, well-formed response for the outstanding request; the invocation is \
           now closed and must not be retried."
        ~contrast:None ();
    ]

let stack_exhausted =
  Diag.error ~domain:Process ~code:"E0003"
    ~summary:"Input exhausted the host stack before a structural nesting guard"
    ~cause:
      "Evaluation of the selected target reached the worker's stack limit before Jacquard could \
       report a local depth boundary."
    ~next_step:"Reduce the target's recursion depth and report the missing structural guard."
    ~contrast:None ()

(* --- frame delivery --- *)

let first_code diagnostics =
  match diagnostics with diagnostic :: _ -> Diag.code_or_uncoded diagnostic | [] -> "E1611"

let deliver operator ~limits output json =
  match Host.write_frame ~limits output json with
  | Ok () -> Terminal_written
  | Error diagnostics ->
      note operator
        (Printf.sprintf "jacquard host worker: the terminal frame could not be written (%s)"
           (first_code diagnostics));
      Carrier_lost

let fatal operator ~limits output diagnostics =
  match Session.fatal ~limits diagnostics with
  | Ok json -> deliver operator ~limits output json
  | Error _ ->
      note operator
        "jacquard host worker: no bounded fatal frame fits the negotiated limits (E1602)";
      Protocol_failure

(* A control frame failed to arrive before any invocation began. Carrier loss still attempts the
   best-effort fatal because stdout may remain writable, but it is reported as lost. *)
let refuse_control operator ~limits output ~phase diagnostics =
  if is_carrier_loss diagnostics then begin
    ignore (fatal operator ~limits output diagnostics);
    note operator
      (Printf.sprintf "jacquard host worker: the carrier was lost while awaiting %s (E1611)" phase);
    Carrier_lost
  end
  else fatal operator ~limits output diagnostics

let message_kind = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with Some (`String kind) -> Some kind | _ -> None)
  | _ -> None

(* --- one invocation --- *)

let run_step ctx state =
  match Eval.run_state_capturing_once_routed ctx state with
  | result -> result
  | exception Stack_overflow -> Error (Runtime_err.Diagnostic stack_exhausted)

let invoke prepared operator ~limits ~input ~output session =
  let ctx = prepared.ctx in
  let terminal = function
    | Ok (Session.Finished json) -> deliver operator ~limits output json
    | Ok (Session.Request _ | Session.Resume _) | Error _ ->
        note operator "jacquard host worker: the session produced an impossible action";
        Internal_failure
  in
  let abort diagnostics = terminal (Session.abort session diagnostics) in
  let runtime_failure error = abort [ Runtime_err.to_diag error ] in
  let rec drive state =
    match run_step ctx state with
    | Error error -> runtime_failure error
    | Ok (Eval.OCValue value) -> terminal (Session.finish session value)
    | Ok (Eval.OCOp { op; args; resume; name = _ }) -> (
        match Session.request session ~operation:op ~arguments:args with
        | Ok (Session.Request request) -> exchange request resume
        | other -> terminal other)
  and exchange request resume =
    match Host.write_frame ~limits output request with
    | Error diagnostics ->
        note operator
          (Printf.sprintf "jacquard host worker: an effect request could not be written (%s)"
             (first_code diagnostics));
        Carrier_lost
    | Ok () -> (
        match Host.read_frame ~limits input with
        | Error diagnostics when is_carrier_loss diagnostics ->
            (* stdout may still be writable: keep the accepted observations and request order
               visible, then report the loss; the host classifies its own outstanding action *)
            ignore (abort diagnostics);
            note operator
              "jacquard host worker: the carrier was lost while awaiting a response (E1611)";
            Carrier_lost
        | Error diagnostics -> abort (invalid_response diagnostics)
        | Ok json -> (
            match Session.respond session json with
            | Ok (Session.Resume value) -> drive (Eval.apply_state ctx resume [ value ])
            | other -> terminal other))
  in
  let callable, arguments = Session.call session in
  let reference = { Kernel.it = Kernel.Ref (callable, Kernel.Term); meta = Meta.empty } in
  match Eval.run_expr ctx reference with
  | Error error -> runtime_failure error
  | Ok callable_value -> drive (Eval.apply_state ctx callable_value arguments)

(* --- one worker lifetime --- *)

(* A host that closes its read end must produce a structured carrier-loss result, not a fatal
   signal. The previous disposition is restored when the lifetime ends. *)
let with_sigpipe_ignored run =
  match Sys.signal Sys.sigpipe Sys.Signal_ignore with
  | previous -> Fun.protect ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous) run
  | exception Invalid_argument _ -> run ()

let serve prepared ~input ~output ~operator =
  let operator =
    { channel = operator; remaining = Host.hard_limits.max_stderr_bytes; truncated = false }
  in
  with_sigpipe_ignored @@ fun () ->
  try
    match Host.write_frame ~limits:Host.hard_limits output (Host.core_hello ()) with
    | Error diagnostics ->
        note operator
          (Printf.sprintf "jacquard host worker: core_hello could not be written (%s)"
             (first_code diagnostics));
        Carrier_lost
    | Ok () -> (
        match Host.read_frame ~limits:Host.hard_limits input with
        | Error diagnostics ->
            refuse_control operator ~limits:Host.hard_limits output ~phase:"host_select" diagnostics
        | Ok json -> (
            match Host.parse_host_select json with
            | Error diagnostics -> fatal operator ~limits:Host.hard_limits output diagnostics
            | Ok limits -> (
                (* the selected ceiling covers the whole lifetime, including bytes already written *)
                let written = Host.hard_limits.max_stderr_bytes - operator.remaining in
                operator.remaining <- max 0 (limits.max_stderr_bytes - written);
                match Host.read_frame ~limits input with
                | Error diagnostics ->
                    refuse_control operator ~limits output ~phase:"invoke" diagnostics
                | Ok json -> (
                    match message_kind json with
                    | Some "shutdown" -> (
                        match Host.parse_shutdown ~limits json with
                        | Error diagnostics -> fatal operator ~limits output diagnostics
                        | Ok () -> deliver operator ~limits output (Host.shutdown_ack ()))
                    | _ -> (
                        match Session.start ~limits ~checker:prepared.checker json with
                        | Error diagnostics -> fatal operator ~limits output diagnostics
                        | Ok session -> invoke prepared operator ~limits ~input ~output session)))))
  with exn ->
    note operator
      (Printf.sprintf "jacquard host worker: internal invariant failed (%s)"
         (Printexc.to_string exn));
    Internal_failure
