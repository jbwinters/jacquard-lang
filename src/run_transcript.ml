(** Explicit, interpreter-only recording for the frozen [run-transcript-v1] observation format. This
    module only constructs and serializes canonical values; parsing and comparison belong to the
    successor RW.2 task. *)

let format_version = 1

type event = { operation : Hash.t; output : string }
type observation = { value : string; trace : event list }
type transcript = Transcript of observation list
type pending_event = { operation : Hash.t; output : string option }

type recorder = {
  mutable completed_rev : observation list;
  mutable current_rev : pending_event list;
  mutable active : bool;
}

exception Bug_run_transcript of string

let bug format = Printf.ksprintf (fun message -> raise (Bug_run_transcript message)) format

(** [create ()] starts an empty, non-reentrant transcript builder. *)
let create () = { completed_rev = []; current_rev = []; active = false }

let on_operation recorder operation =
  if not recorder.active then bug "root operation arrived outside an active recording";
  recorder.current_rev <- { operation; output = None } :: recorder.current_rev

let on_output recorder operation output =
  if not recorder.active then bug "root output arrived outside an active recording";
  let rec attach seen = function
    | [] -> bug "root output for %s has no pending root operation" (Hash.to_hex operation)
    | ({ operation = current; output = None } as event) :: rest when Hash.equal current operation ->
        List.rev_append seen ({ event with output = Some output } :: rest)
    | event :: rest -> attach (event :: seen) rest
  in
  recorder.current_rev <- attach [] recorder.current_rev

(** [record_expression recorder ctx run] observes one caller-supplied evaluator or scheduler run.
    The original result is preserved exactly; only a successful [Value.t] adds an observation. *)
let record_expression recorder ctx run =
  if recorder.active then bug "a recorder cannot record overlapping expressions";
  recorder.active <- true;
  recorder.current_rev <- [];
  Fun.protect
    ~finally:(fun () ->
      recorder.current_rev <- [];
      recorder.active <- false)
    (fun () ->
      Eval.with_root_observer ctx ~on_operation:(on_operation recorder)
        ~on_output:(on_output recorder) (fun () ->
          match run () with
          | Ok value as result ->
              let observation =
                {
                  value = Value.show value ^ "\n";
                  trace =
                    List.rev_map
                      (fun (pending : pending_event) ->
                        let output = Option.value ~default:"" pending.output in
                        ({ operation = pending.operation; output } : event))
                      recorder.current_rev;
                }
              in
              recorder.completed_rev <- observation :: recorder.completed_rev;
              result
          | Error _ as result -> result))

(** [transcript recorder] snapshots completed observations. In-progress observations are never
    exposed because they are discarded on a failed or abandoned expression. *)
let transcript recorder =
  if recorder.active then bug "cannot inspect a recorder while an expression is active";
  Transcript (List.rev recorder.completed_rev)

let observations (Transcript observations) = observations

let decimal value =
  if value < 0 then bug "negative canonical count or byte length";
  string_of_int value

let add_header buffer index observation =
  Buffer.add_string buffer "observation index=";
  Buffer.add_string buffer (decimal index);
  Buffer.add_string buffer " value-bytes=";
  Buffer.add_string buffer (decimal (String.length observation.value));
  Buffer.add_string buffer " trace-events=";
  Buffer.add_string buffer (decimal (List.length observation.trace));
  Buffer.add_char buffer '\n';
  Buffer.add_string buffer observation.value

let add_event buffer index (event : event) =
  Buffer.add_string buffer "trace index=";
  Buffer.add_string buffer (decimal index);
  Buffer.add_string buffer " operation=";
  Buffer.add_string buffer (Hash.to_hex event.operation);
  Buffer.add_string buffer " output-bytes=";
  Buffer.add_string buffer (decimal (String.length event.output));
  Buffer.add_char buffer '\n';
  Buffer.add_string buffer event.output

(** [serialize] writes one header and length-framed raw result/output payloads. All indices are
    generated from immutable list order, so callers cannot construct noncontiguous encodings. *)
let serialize (Transcript completed) =
  let buffer = Buffer.create 256 in
  Buffer.add_string buffer "jacquard-run-transcript format=";
  Buffer.add_string buffer (decimal format_version);
  Buffer.add_string buffer " observations=";
  Buffer.add_string buffer (decimal (List.length completed));
  Buffer.add_char buffer '\n';
  List.iteri
    (fun observation_index observation ->
      add_header buffer observation_index observation;
      List.iteri (add_event buffer) observation.trace)
    completed;
  Buffer.contents buffer

let serialize_recorder recorder = serialize (transcript recorder)
