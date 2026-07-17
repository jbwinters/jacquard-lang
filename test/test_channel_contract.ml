open Jacquard

let opened ~capacity =
  match Channel_contract.open_channel ~scope_path:[ 0 ] ~open_index:0 ~capacity with
  | Opened channel -> channel
  | Invalid_capacity _ -> Alcotest.fail "expected valid channel capacity"

let check_counts channel ~buffered ~senders ~receivers =
  let view = Channel_contract.view channel in
  Alcotest.(check int) "buffered" buffered view.buffered;
  Alcotest.(check int) "waiting senders" senders view.waiting_senders;
  Alcotest.(check int) "waiting receivers" receivers view.waiting_receivers

let state_text channel =
  let snapshot = Channel_contract.snapshot channel in
  let values values = match values with [] -> "-" | values -> String.concat "," values in
  let senders =
    snapshot.snapshot_senders
    |> List.map (fun sender ->
        sender.Channel_contract.sender ^ ":" ^ sender.Channel_contract.sent_value)
    |> values
  in
  let receivers =
    snapshot.snapshot_receivers
    |> List.map (fun receiver -> receiver.Channel_contract.receiver)
    |> values
  in
  Printf.sprintf "%s|buffer=%s|senders=%s|receivers=%s"
    (if snapshot.snapshot_closed then "closed" else "open")
    (values snapshot.snapshot_buffer) senders receivers

let trace_line ~decision ~task ~op ~before ~action ~after ~result ~wake =
  Printf.sprintf "decision=%d task=%s op=%s before=%s action=%s after=%s result=%s wake=%s" decision
    task op before action after result wake

let fixture_lines path = Corpus_support.read_file path |> String.trim |> String.split_on_char '\n'

let check_trace_fixture path actual =
  Alcotest.(check (list string)) path (fixture_lines path) actual

let test_rendezvous_trace_fixture () =
  let lines =
    ref [ "jacquard-channel-contract format=1 scenario=rendezvous channel=0@0 capacity=0" ]
  in
  let add line = lines := !lines @ [ line ] in
  (match Channel_contract.open_channel ~scope_path:[] ~open_index:(-1) ~capacity:(-1) with
  | Invalid_capacity -1 ->
      add
        (trace_line ~decision:0 ~task:"0#0" ~op:"open:-1" ~before:"-" ~action:"reject-capacity"
           ~after:"-" ~result:"error:invalid-capacity:-1" ~wake:"0#0")
  | _ -> Alcotest.fail "trace negative capacity was not rejected first");
  let channel = opened ~capacity:0 in
  add
    (trace_line ~decision:1 ~task:"0#0" ~op:"open:0" ~before:"-" ~action:"create"
       ~after:(state_text channel) ~result:"ok:0@0" ~wake:"0#0");
  let before = state_text channel in
  (match Channel_contract.send channel ~sender:"0#1" ~value:"7" with
  | Send_blocked -> ()
  | _ -> Alcotest.fail "trace sender did not block");
  add
    (trace_line ~decision:2 ~task:"0#1" ~op:"send:7" ~before ~action:"block-sender"
       ~after:(state_text channel) ~result:"pending" ~wake:"-");
  let before = state_text channel in
  (match Channel_contract.recv channel ~receiver:"0#2" with
  | Recv_delivered { value = "7"; completed_sender = Some sender } ->
      add
        (trace_line ~decision:3 ~task:"0#2" ~op:"recv" ~before
           ~action:("rendezvous:" ^ sender.sender) ~after:(state_text channel)
           ~result:"receiver-ok:7,sender-ok:unit" ~wake:(sender.sender ^ ",0#2"))
  | _ -> Alcotest.fail "trace rendezvous mismatch");
  List.iteri
    (fun offset receiver ->
      let before = state_text channel in
      match Channel_contract.recv channel ~receiver with
      | Recv_blocked ->
          add
            (trace_line ~decision:(4 + offset) ~task:receiver ~op:"recv" ~before
               ~action:"block-receiver" ~after:(state_text channel) ~result:"pending" ~wake:"-")
      | _ -> Alcotest.fail "trace receiver did not block")
    [ "0#3"; "0#4" ];
  let before = state_text channel in
  (match Channel_contract.cancel ~equal_task:String.equal channel "0#3" with
  | Cancelled_receiver receiver ->
      add
        (trace_line ~decision:6 ~task:"0#0" ~op:"cancel:0#3" ~before
           ~action:("cancel-receiver:" ^ receiver.receiver)
           ~after:(state_text channel) ~result:"unit,target-cancelled" ~wake:"0#0")
  | _ -> Alcotest.fail "trace receiver cancellation mismatch");
  let before = state_text channel in
  let closed = Channel_contract.close channel in
  let rejected =
    List.map (fun receiver -> receiver.Channel_contract.receiver) closed.rejected_receivers
  in
  add
    (trace_line ~decision:7 ~task:"0#0" ~op:"close" ~before ~action:"close,reject-receivers"
       ~after:(state_text channel) ~result:"closer-unit,receiver-error:0#4:channel-closed"
       ~wake:(String.concat "," (rejected @ [ "0#0" ])));
  let before = state_text channel in
  (match Channel_contract.recv channel ~receiver:"0#2" with
  | Recv_closed ->
      add
        (trace_line ~decision:8 ~task:"0#2" ~op:"recv" ~before ~action:"closed-empty"
           ~after:(state_text channel) ~result:"error:channel-closed" ~wake:"0#2")
  | _ -> Alcotest.fail "trace closed receive mismatch");
  let before = state_text channel in
  ignore (Channel_contract.close channel);
  add
    (trace_line ~decision:9 ~task:"0#0" ~op:"close" ~before ~action:"already-closed"
       ~after:(state_text channel) ~result:"unit" ~wake:"0#0");
  check_trace_fixture "../corpus/channel/rendezvous-v1.trace" !lines

let test_buffered_trace_fixture () =
  let lines =
    ref [ "jacquard-channel-contract format=1 scenario=buffered channel=0@0 capacity=2" ]
  in
  let add line = lines := !lines @ [ line ] in
  let channel = opened ~capacity:2 in
  add
    (trace_line ~decision:0 ~task:"0#0" ~op:"open:2" ~before:"-" ~action:"create"
       ~after:(state_text channel) ~result:"ok:0@0" ~wake:"0#0");
  let send decision task value action result wake =
    let before = state_text channel in
    let outcome = Channel_contract.send channel ~sender:task ~value in
    add
      (trace_line ~decision ~task ~op:("send:" ^ value) ~before ~action ~after:(state_text channel)
         ~result ~wake);
    outcome
  in
  ignore (send 1 "0#1" "a" "buffer" "ok:unit" "0#1");
  ignore (send 2 "0#2" "b" "buffer" "ok:unit" "0#2");
  ignore (send 3 "0#3" "c" "block-sender" "pending" "-");
  let before = state_text channel in
  (match Channel_contract.recv channel ~receiver:"0#4" with
  | Recv_delivered { value = "a"; completed_sender = Some sender } ->
      add
        (trace_line ~decision:4 ~task:"0#4" ~op:"recv" ~before
           ~action:("dequeue:a,promote:" ^ sender.sender ^ ":" ^ sender.sent_value)
           ~after:(state_text channel) ~result:"receiver-ok:a,sender-ok:unit"
           ~wake:(sender.sender ^ ",0#4"))
  | _ -> Alcotest.fail "trace promotion mismatch");
  ignore (send 5 "0#5" "d" "block-sender" "pending" "-");
  ignore (send 6 "0#6" "e" "block-sender" "pending" "-");
  let before = state_text channel in
  (match Channel_contract.cancel ~equal_task:String.equal channel "0#5" with
  | Cancelled_sender sender ->
      add
        (trace_line ~decision:7 ~task:"0#0" ~op:"cancel:0#5" ~before
           ~action:("cancel-sender:" ^ sender.sender ^ "-drop:" ^ sender.sent_value)
           ~after:(state_text channel) ~result:"unit,target-cancelled" ~wake:"0#0")
  | _ -> Alcotest.fail "trace sender cancellation mismatch");
  ignore (send 8 "0#7" "f" "block-sender" "pending" "-");
  let before = state_text channel in
  let closed = Channel_contract.close channel in
  let rejected = List.map (fun sender -> sender.Channel_contract.sender) closed.rejected_senders in
  add
    (trace_line ~decision:9 ~task:"0#0" ~op:"close" ~before ~action:"close,reject-senders"
       ~after:(state_text channel)
       ~result:"closer-unit,sender-error:0#6:channel-closed,sender-error:0#7:channel-closed"
       ~wake:(String.concat "," (rejected @ [ "0#0" ])));
  List.iteri
    (fun offset expected ->
      let before = state_text channel in
      match Channel_contract.recv channel ~receiver:"0#4" with
      | Recv_delivered { value; completed_sender = None } when String.equal value expected ->
          add
            (trace_line ~decision:(10 + offset) ~task:"0#4" ~op:"recv" ~before
               ~action:("drain:" ^ value) ~after:(state_text channel) ~result:("ok:" ^ value)
               ~wake:"0#4")
      | _ -> Alcotest.fail "trace close drain mismatch")
    [ "b"; "c" ];
  let before = state_text channel in
  (match Channel_contract.recv channel ~receiver:"0#4" with
  | Recv_closed ->
      add
        (trace_line ~decision:12 ~task:"0#4" ~op:"recv" ~before ~action:"closed-empty"
           ~after:(state_text channel) ~result:"error:channel-closed" ~wake:"0#4")
  | _ -> Alcotest.fail "trace final close mismatch");
  check_trace_fixture "../corpus/channel/buffered-v1.trace" !lines

let test_negative_capacity_consumes_no_identity () =
  match Channel_contract.open_channel ~scope_path:[] ~open_index:(-1) ~capacity:(-3) with
  | Invalid_capacity -3 -> ()
  | Invalid_capacity other -> Alcotest.failf "wrong rejected capacity %d" other
  | Opened _ -> Alcotest.fail "negative capacity opened"

let test_frozen_identities_and_id_bounds () =
  Alcotest.(check string)
    "handle hash" "f4f5601a435906a47faedae9006e44b874146f3ad4b586bf9d04535be14dccb4"
    Channel_contract.channel_handle_type_hash;
  Alcotest.(check string)
    "opaque hash" "dc7a12f5fc0476b674d52535e9895220edf41f2a017b1dd97fc078950a3dbb36"
    Channel_contract.channel_opaque_constructor_hash;
  Alcotest.(check string)
    "error hash" "25dc8f513c91c80fd6d33e843fc3f6cab183800805f46e269f716155149b4da7"
    Channel_contract.channel_error_type_hash;
  Alcotest.(check string)
    "closed hash" "de3da3e601fbba2c66864b87c6848d8224411df99f1967e132aaa166c1a3f3a9"
    Channel_contract.channel_closed_constructor_hash;
  Alcotest.(check string)
    "invalid capacity hash" "01b719cb597275f097c2c36b5e86b3d71604eb531fe00ef66d9c93ec3f55acfb"
    Channel_contract.invalid_capacity_constructor_hash;
  Alcotest.(check string)
    "effect hash" "bf9a334188ac13495eeb070fdc215d51763d9761b4775c98c61f44ebb1b03756"
    Channel_contract.channel_effect_hash;
  Alcotest.(check (list string))
    "operation order"
    [ "channel.open"; "channel.send"; "channel.recv"; "channel.close" ]
    (List.map fst Channel_contract.channel_operation_hashes);
  let opaque = Option.get (Hash.of_hex Channel_contract.channel_opaque_constructor_hash) in
  Alcotest.(check bool)
    "only opaque is private" true
    (Channel_contract.is_channel_private_hash opaque
    && not (Channel_contract.is_channel_private_hash (Hash.of_string "near-channel")));
  let id = Channel_contract.channel_id ~scope_path:[ 0; 2 ] ~open_index:3 in
  Alcotest.(check string) "trace spelling" "0/2@3" (Channel_contract.trace_channel_id id);
  let rejects build =
    match build () with exception Channel_contract.Bug_invalid_channel_id _ -> true | _ -> false
  in
  Alcotest.(check bool)
    "empty path rejected" true
    (rejects (fun () -> Channel_contract.channel_id ~scope_path:[] ~open_index:0));
  Alcotest.(check bool)
    "non-root path rejected" true
    (rejects (fun () -> Channel_contract.channel_id ~scope_path:[ 1 ] ~open_index:0));
  Alcotest.(check bool)
    "negative index rejected" true
    (rejects (fun () -> Channel_contract.channel_id ~scope_path:[ 0 ] ~open_index:(-1)))

let test_rendezvous_fifo () =
  let channel = opened ~capacity:0 in
  (match Channel_contract.send channel ~sender:"s1" ~value:"one" with
  | Send_blocked -> ()
  | _ -> Alcotest.fail "first rendezvous sender did not block");
  (match Channel_contract.send channel ~sender:"s2" ~value:"two" with
  | Send_blocked -> ()
  | _ -> Alcotest.fail "second rendezvous sender did not block");
  (match Channel_contract.recv channel ~receiver:"r1" with
  | Recv_delivered { value = "one"; completed_sender = Some sender } ->
      Alcotest.(check string) "oldest sender" "s1" sender.sender
  | _ -> Alcotest.fail "receive did not rendezvous with oldest sender");
  (match Channel_contract.recv channel ~receiver:"r2" with
  | Recv_delivered { value = "two"; completed_sender = Some sender } ->
      Alcotest.(check string) "next sender" "s2" sender.sender
  | _ -> Alcotest.fail "second receive did not preserve FIFO");
  check_counts channel ~buffered:0 ~senders:0 ~receivers:0

let test_receiver_handoff_fifo () =
  let channel = opened ~capacity:0 in
  ignore (Channel_contract.recv channel ~receiver:"r1");
  ignore (Channel_contract.recv channel ~receiver:"r2");
  (match Channel_contract.send channel ~sender:"s1" ~value:"one" with
  | Send_delivered receiver -> Alcotest.(check string) "oldest receiver" "r1" receiver.receiver
  | _ -> Alcotest.fail "send did not hand off to oldest receiver");
  match Channel_contract.send channel ~sender:"s2" ~value:"two" with
  | Send_delivered receiver -> Alcotest.(check string) "next receiver" "r2" receiver.receiver
  | _ -> Alcotest.fail "second send did not preserve receiver FIFO"

let test_bounded_fifo_and_promotion () =
  let channel = opened ~capacity:2 in
  Alcotest.(check bool)
    "buffer one" true
    (Channel_contract.send channel ~sender:"s1" ~value:"one" = Send_completed);
  Alcotest.(check bool)
    "buffer two" true
    (Channel_contract.send channel ~sender:"s2" ~value:"two" = Send_completed);
  ignore (Channel_contract.send channel ~sender:"s3" ~value:"three");
  (match Channel_contract.recv channel ~receiver:"r" with
  | Recv_delivered { value = "one"; completed_sender = Some sender } ->
      Alcotest.(check string) "promoted oldest sender" "s3" sender.sender
  | _ -> Alcotest.fail "buffer pop did not promote blocked sender");
  let values =
    List.init 2 (fun index ->
        match Channel_contract.recv channel ~receiver:("r" ^ string_of_int index) with
        | Recv_delivered { value; completed_sender = None } -> value
        | _ -> Alcotest.fail "expected buffered value")
  in
  Alcotest.(check (list string)) "FIFO values" [ "two"; "three" ] values

let test_close_drains_and_is_idempotent () =
  let channel = opened ~capacity:1 in
  ignore (Channel_contract.send channel ~sender:"s1" ~value:"one");
  ignore (Channel_contract.send channel ~sender:"s2" ~value:"two");
  let closed = Channel_contract.close channel in
  Alcotest.(check (list string))
    "blocked senders rejected" [ "s2" ]
    (List.map (fun sender -> sender.Channel_contract.sender) closed.rejected_senders);
  Alcotest.(check int) "buffer preserved" 1 (Channel_contract.view channel).buffered;
  (match Channel_contract.recv channel ~receiver:"r" with
  | Recv_delivered { value = "one"; completed_sender = None } -> ()
  | _ -> Alcotest.fail "close did not preserve drainable value");
  Alcotest.(check bool)
    "drained receive closes" true
    (Channel_contract.recv channel ~receiver:"r" = Recv_closed);
  Alcotest.(check bool)
    "send after close rejected" true
    (Channel_contract.send channel ~sender:"s3" ~value:"three" = Send_closed);
  let repeated = Channel_contract.close channel in
  Alcotest.(check int)
    "repeated close wakes nobody" 0
    (List.length repeated.rejected_senders + List.length repeated.rejected_receivers)

let test_cancel_preserves_survivor_order () =
  let channel = opened ~capacity:0 in
  List.iter
    (fun (sender, value) -> ignore (Channel_contract.send channel ~sender ~value))
    [ ("s1", "one"); ("s2", "two"); ("s3", "three") ];
  (match Channel_contract.cancel ~equal_task:String.equal channel "s2" with
  | Cancelled_sender sender -> Alcotest.(check string) "cancelled middle" "two" sender.sent_value
  | _ -> Alcotest.fail "middle sender was not removed");
  let recv_value name =
    match Channel_contract.recv channel ~receiver:name with
    | Recv_delivered { value; completed_sender = Some _ } -> value
    | _ -> Alcotest.fail "surviving sender was lost"
  in
  let first = recv_value "r1" in
  let second = recv_value "r2" in
  Alcotest.(check (list string)) "survivor FIFO" [ "one"; "three" ] [ first; second ]

let test_teardown_transfers_once () =
  let channel = opened ~capacity:1 in
  ignore (Channel_contract.send channel ~sender:"s1" ~value:"one");
  ignore (Channel_contract.send channel ~sender:"s2" ~value:"two");
  let first = Channel_contract.teardown channel in
  Alcotest.(check (list string)) "buffer ownership" [ "one" ] first.dropped_values;
  Alcotest.(check (list string))
    "sender ownership" [ "two" ]
    (List.map (fun sender -> sender.Channel_contract.sent_value) first.dropped_senders);
  let second = Channel_contract.teardown channel in
  Alcotest.(check int)
    "nothing transferred twice" 0
    (List.length second.dropped_values
    + List.length second.dropped_senders
    + List.length second.dropped_receivers)

let prop_fifo_no_loss_or_duplication =
  let open QCheck in
  let generator =
    let open Gen in
    pair (0 -- 5) (list_size (0 -- 40) nat_small) |> make
  in
  Test.make ~count:500 ~name:"buffer/rendezvous preserves every payload exactly once" generator
    (fun (capacity, values) ->
      let channel = opened ~capacity in
      List.iteri (fun sender value -> ignore (Channel_contract.send channel ~sender ~value)) values;
      let rec drain receiver reversed =
        if receiver = List.length values then List.rev reversed
        else
          match Channel_contract.recv channel ~receiver with
          | Recv_delivered { value; _ } -> drain (receiver + 1) (value :: reversed)
          | Recv_blocked | Recv_closed -> []
      in
      let delivered = drain 0 [] in
      let state = Channel_contract.view channel in
      delivered = values && state.buffered = 0 && state.waiting_senders = 0
      && state.waiting_receivers = 0)

type model = {
  capacity : int;
  closed : bool;
  torn_down : bool;
  buffer : int list;
  senders : (int * int) list;
  receivers : int list;
}

type normalized =
  | N_send_completed
  | N_send_delivered of int
  | N_send_blocked
  | N_send_closed
  | N_recv_delivered of int * int option
  | N_recv_blocked
  | N_recv_closed
  | N_cancel_sender of int * int
  | N_cancel_receiver of int
  | N_not_blocked
  | N_close of (int * int) list * int list
  | N_teardown of int list * (int * int) list * int list

let remove_first_by_task task pairs =
  let rec loop reversed = function
    | [] -> (None, List.rev reversed)
    | ((candidate, _) as pair) :: rest when candidate = task ->
        (Some pair, List.rev_append reversed rest)
    | pair :: rest -> loop (pair :: reversed) rest
  in
  loop [] pairs

let remove_first_receiver task receivers =
  let rec loop reversed = function
    | [] -> (false, List.rev reversed)
    | candidate :: rest when candidate = task -> (true, List.rev_append reversed rest)
    | candidate :: rest -> loop (candidate :: reversed) rest
  in
  loop [] receivers

let model_send model task payload =
  if model.closed then (model, N_send_closed)
  else
    match model.receivers with
    | receiver :: receivers -> ({ model with receivers }, N_send_delivered receiver)
    | [] when List.length model.buffer < model.capacity ->
        ({ model with buffer = model.buffer @ [ payload ] }, N_send_completed)
    | [] -> ({ model with senders = model.senders @ [ (task, payload) ] }, N_send_blocked)

let model_recv model task =
  match model.buffer with
  | value :: buffer -> (
      match model.senders with
      | (sender, promoted) :: senders ->
          ( { model with buffer = buffer @ [ promoted ]; senders },
            N_recv_delivered (value, Some sender) )
      | [] -> ({ model with buffer }, N_recv_delivered (value, None)))
  | [] -> (
      match model.senders with
      | (sender, value) :: senders -> ({ model with senders }, N_recv_delivered (value, Some sender))
      | [] when model.closed -> (model, N_recv_closed)
      | [] -> ({ model with receivers = model.receivers @ [ task ] }, N_recv_blocked))

let model_cancel model task =
  let sender, senders = remove_first_by_task task model.senders in
  match sender with
  | Some (sender, payload) -> ({ model with senders }, N_cancel_sender (sender, payload))
  | None ->
      let found, receivers = remove_first_receiver task model.receivers in
      if found then ({ model with receivers }, N_cancel_receiver task) else (model, N_not_blocked)

let model_close model =
  if model.closed then (model, N_close ([], []))
  else
    let rejected_receivers = if model.buffer = [] then model.receivers else [] in
    ( {
        model with
        closed = true;
        senders = [];
        receivers = (if model.buffer = [] then [] else model.receivers);
      },
      N_close (model.senders, rejected_receivers) )

let model_teardown model =
  if model.torn_down then (model, N_teardown ([], [], []))
  else
    ( { model with closed = true; torn_down = true; buffer = []; senders = []; receivers = [] },
      N_teardown (model.buffer, model.senders, model.receivers) )

let implementation_state channel =
  let snapshot = Channel_contract.snapshot channel in
  ( snapshot.snapshot_closed,
    snapshot.snapshot_buffer,
    List.map
      (fun sender -> (sender.Channel_contract.sender, sender.Channel_contract.sent_value))
      snapshot.snapshot_senders,
    List.map (fun receiver -> receiver.Channel_contract.receiver) snapshot.snapshot_receivers )

let model_state model = (model.closed, model.buffer, model.senders, model.receivers)

let observed_payloads = function
  | N_send_delivered _ | N_send_closed -> `Current
  | N_recv_delivered (value, _) -> `Values [ value ]
  | N_cancel_sender (_, value) -> `Values [ value ]
  | N_close (senders, _) -> `Values (List.map snd senders)
  | N_teardown (buffer, senders, _) -> `Values (buffer @ List.map snd senders)
  | N_send_completed | N_send_blocked | N_recv_blocked | N_recv_closed | N_cancel_receiver _
  | N_not_blocked ->
      `Values []

let prop_mixed_reference_model =
  let open QCheck in
  let generator =
    let open Gen in
    pair (0 -- 3) (list_size (0 -- 120) (pair (0 -- 4) (0 -- 9))) |> make
  in
  Test.make ~count:500
    ~name:"mixed send/recv/cancel/close/teardown agrees with FIFO reference model" generator
    (fun (capacity, operations) ->
      let channel = opened ~capacity in
      let initial =
        { capacity; closed = false; torn_down = false; buffer = []; senders = []; receivers = [] }
      in
      let rec run index model sent observed = function
        | [] -> true
        | (tag, task) :: rest ->
            let payload = index in
            let model, expected, actual, sent =
              match tag with
              | 0 ->
                  let model, expected = model_send model task payload in
                  let actual =
                    match Channel_contract.send channel ~sender:task ~value:payload with
                    | Send_completed -> N_send_completed
                    | Send_delivered receiver -> N_send_delivered receiver.receiver
                    | Send_blocked -> N_send_blocked
                    | Send_closed -> N_send_closed
                  in
                  (model, expected, actual, payload :: sent)
              | 1 ->
                  let model, expected = model_recv model task in
                  let actual =
                    match Channel_contract.recv channel ~receiver:task with
                    | Recv_delivered { value; completed_sender } ->
                        N_recv_delivered
                          ( value,
                            Option.map
                              (fun sender -> sender.Channel_contract.sender)
                              completed_sender )
                    | Recv_blocked -> N_recv_blocked
                    | Recv_closed -> N_recv_closed
                  in
                  (model, expected, actual, sent)
              | 2 ->
                  let model, expected = model_cancel model task in
                  let actual =
                    match Channel_contract.cancel ~equal_task:Int.equal channel task with
                    | Cancelled_sender sender ->
                        N_cancel_sender
                          (sender.Channel_contract.sender, sender.Channel_contract.sent_value)
                    | Cancelled_receiver receiver ->
                        N_cancel_receiver receiver.Channel_contract.receiver
                    | Not_blocked -> N_not_blocked
                  in
                  (model, expected, actual, sent)
              | 3 ->
                  let model, expected = model_close model in
                  let actual_close = Channel_contract.close channel in
                  let actual =
                    N_close
                      ( List.map
                          (fun sender ->
                            (sender.Channel_contract.sender, sender.Channel_contract.sent_value))
                          actual_close.rejected_senders,
                        List.map
                          (fun receiver -> receiver.Channel_contract.receiver)
                          actual_close.rejected_receivers )
                  in
                  (model, expected, actual, sent)
              | _ ->
                  let model, expected = model_teardown model in
                  let actual_teardown = Channel_contract.teardown channel in
                  let actual =
                    N_teardown
                      ( actual_teardown.dropped_values,
                        List.map
                          (fun sender ->
                            (sender.Channel_contract.sender, sender.Channel_contract.sent_value))
                          actual_teardown.dropped_senders,
                        List.map
                          (fun receiver -> receiver.Channel_contract.receiver)
                          actual_teardown.dropped_receivers )
                  in
                  (model, expected, actual, sent)
            in
            let observed =
              match observed_payloads actual with
              | `Current -> payload :: observed
              | `Values values -> values @ observed
            in
            let snapshot = Channel_contract.snapshot channel in
            let outstanding =
              snapshot.snapshot_buffer
              @ List.map
                  (fun sender -> sender.Channel_contract.sent_value)
                  snapshot.snapshot_senders
            in
            let conserved =
              List.sort Int.compare sent = List.sort Int.compare (observed @ outstanding)
            in
            let no_duplication =
              let all = observed @ outstanding in
              List.length all = List.length (List.sort_uniq Int.compare all)
            in
            expected = actual
            && implementation_state channel = model_state model
            && conserved && no_duplication
            && run (index + 1) model sent observed rest
      in
      run 0 initial [] [] operations)

let suite =
  [
    Alcotest.test_case "negative capacity allocates nothing" `Quick
      test_negative_capacity_consumes_no_identity;
    Alcotest.test_case "frozen identities and ID bounds" `Quick test_frozen_identities_and_id_bounds;
    Alcotest.test_case "rendezvous sender FIFO" `Quick test_rendezvous_fifo;
    Alcotest.test_case "rendezvous receiver FIFO" `Quick test_receiver_handoff_fifo;
    Alcotest.test_case "bounded FIFO promotes sender" `Quick test_bounded_fifo_and_promotion;
    Alcotest.test_case "close drains and is idempotent" `Quick test_close_drains_and_is_idempotent;
    Alcotest.test_case "cancellation preserves FIFO" `Quick test_cancel_preserves_survivor_order;
    Alcotest.test_case "teardown transfers ownership once" `Quick test_teardown_transfers_once;
    Alcotest.test_case "frozen rendezvous trace" `Quick test_rendezvous_trace_fixture;
    Alcotest.test_case "frozen buffered trace" `Quick test_buffered_trace_fixture;
    QCheck_alcotest.to_alcotest prop_fifo_no_loss_or_duplication;
    QCheck_alcotest.to_alcotest prop_mixed_reference_model;
  ]
