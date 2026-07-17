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

let test_negative_capacity_consumes_no_identity () =
  match Channel_contract.open_channel ~scope_path:[] ~open_index:(-1) ~capacity:(-3) with
  | Invalid_capacity -3 -> ()
  | Invalid_capacity other -> Alcotest.failf "wrong rejected capacity %d" other
  | Opened _ -> Alcotest.fail "negative capacity opened"

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

let suite =
  [
    Alcotest.test_case "negative capacity allocates nothing" `Quick
      test_negative_capacity_consumes_no_identity;
    Alcotest.test_case "rendezvous sender FIFO" `Quick test_rendezvous_fifo;
    Alcotest.test_case "rendezvous receiver FIFO" `Quick test_receiver_handoff_fifo;
    Alcotest.test_case "bounded FIFO promotes sender" `Quick test_bounded_fifo_and_promotion;
    Alcotest.test_case "close drains and is idempotent" `Quick test_close_drains_and_is_idempotent;
    Alcotest.test_case "cancellation preserves FIFO" `Quick test_cancel_preserves_survivor_order;
    Alcotest.test_case "teardown transfers ownership once" `Quick test_teardown_transfers_once;
    QCheck_alcotest.to_alcotest prop_fifo_no_loss_or_duplication;
  ]
