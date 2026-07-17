exception Bug_invalid_channel_id of string

let channel_handle_type_hash = "f4f5601a435906a47faedae9006e44b874146f3ad4b586bf9d04535be14dccb4"

let channel_opaque_constructor_hash =
  "dc7a12f5fc0476b674d52535e9895220edf41f2a017b1dd97fc078950a3dbb36"

let channel_error_type_hash = "25dc8f513c91c80fd6d33e843fc3f6cab183800805f46e269f716155149b4da7"

let channel_closed_constructor_hash =
  "de3da3e601fbba2c66864b87c6848d8224411df99f1967e132aaa166c1a3f3a9"

let invalid_capacity_constructor_hash =
  "01b719cb597275f097c2c36b5e86b3d71604eb531fe00ef66d9c93ec3f55acfb"

let channel_effect_hash = "bf9a334188ac13495eeb070fdc215d51763d9761b4775c98c61f44ebb1b03756"

let channel_operation_hashes =
  [
    ("channel.open", "23f13bd2fd87d17716873bf34c708d6c9a2ddd5f2b4e4f634db6e5d1827b1f07");
    ("channel.send", "348fc5c967097b939360ecb2b066ba22ea8b924834e507c87a0e0f05f26fbfb0");
    ("channel.recv", "db28d70a061da1f1108e01dfaa7e248c4268b9460971c518a9c37f1b51b52860");
    ("channel.close", "ffa22eb01ff7aa206fec56f540b6fd1758b8590e8e797e83f3cbfd295ebce29b");
  ]

let is_channel_private_hash hash = String.equal (Hash.to_hex hash) channel_opaque_constructor_hash

type channel_id = { scope_path : int list; open_index : int }

let max_component = Int64.to_int 0xffff_ffffL
let max_scope_depth = 65532

let validate_scope_path scope_path =
  if scope_path = [] || List.hd scope_path <> 0 then
    raise (Bug_invalid_channel_id "scoped-channel paths must start at root component 0");
  if List.length scope_path > max_scope_depth then
    raise (Bug_invalid_channel_id "scoped-channel paths exceed the native block-length domain");
  if List.exists (fun component -> component <= 0) (List.tl scope_path) then
    raise (Bug_invalid_channel_id "nested channel scope components must be positive ordinals");
  if List.exists (fun component -> component > max_component) scope_path then
    raise (Bug_invalid_channel_id "channel scope components exceed the uint32 domain")

let channel_id ~scope_path ~open_index =
  validate_scope_path scope_path;
  if open_index < 0 then
    raise (Bug_invalid_channel_id "successful-open indices must be non-negative");
  if open_index > max_component then
    raise (Bug_invalid_channel_id "successful-open indices exceed the uint32 domain");
  { scope_path; open_index }

let compare_channel_id left right =
  match List.compare Int.compare left.scope_path right.scope_path with
  | 0 -> Int.compare left.open_index right.open_index
  | order -> order

let trace_channel_id id =
  String.concat "/" (List.map string_of_int id.scope_path) ^ "@" ^ string_of_int id.open_index

type ('task, 'value) pending_sender = { sender : 'task; sent_value : 'value }
type 'task pending_receiver = { receiver : 'task }

type ('task, 'value) t = {
  id : channel_id;
  capacity : int;
  mutable closed : bool;
  mutable torn_down : bool;
  mutable buffer : 'value list;
  mutable senders : ('task, 'value) pending_sender list;
  mutable receivers : 'task pending_receiver list;
}

type ('task, 'value) opening = Opened of ('task, 'value) t | Invalid_capacity of int

let open_channel ~scope_path ~open_index ~capacity =
  if capacity < 0 then Invalid_capacity capacity
  else
    let id = channel_id ~scope_path ~open_index in
    Opened
      { id; capacity; closed = false; torn_down = false; buffer = []; senders = []; receivers = [] }

type 'task send_outcome =
  | Send_completed
  | Send_delivered of 'task pending_receiver
  | Send_blocked
  | Send_closed

let send channel ~sender ~value =
  if channel.closed then Send_closed
  else
    match channel.receivers with
    | receiver :: receivers ->
        channel.receivers <- receivers;
        Send_delivered receiver
    | [] when List.length channel.buffer < channel.capacity ->
        channel.buffer <- channel.buffer @ [ value ];
        Send_completed
    | [] ->
        channel.senders <- channel.senders @ [ { sender; sent_value = value } ];
        Send_blocked

type ('task, 'value) recv_outcome =
  | Recv_delivered of { value : 'value; completed_sender : ('task, 'value) pending_sender option }
  | Recv_blocked
  | Recv_closed

let recv channel ~receiver =
  match channel.buffer with
  | value :: buffer ->
      channel.buffer <- buffer;
      let completed_sender =
        match channel.senders with
        | sender :: senders ->
            channel.senders <- senders;
            channel.buffer <- channel.buffer @ [ sender.sent_value ];
            Some sender
        | [] -> None
      in
      Recv_delivered { value; completed_sender }
  | [] -> (
      match channel.senders with
      | sender :: senders ->
          channel.senders <- senders;
          Recv_delivered { value = sender.sent_value; completed_sender = Some sender }
      | [] when channel.closed -> Recv_closed
      | [] ->
          channel.receivers <- channel.receivers @ [ { receiver } ];
          Recv_blocked)

type ('task, 'value) close_outcome = {
  rejected_senders : ('task, 'value) pending_sender list;
  rejected_receivers : 'task pending_receiver list;
}

let close channel =
  if channel.closed then { rejected_senders = []; rejected_receivers = [] }
  else
    let rejected_senders = channel.senders in
    let rejected_receivers = if channel.buffer = [] then channel.receivers else [] in
    channel.closed <- true;
    channel.senders <- [];
    if channel.buffer = [] then channel.receivers <- [];
    { rejected_senders; rejected_receivers }

type ('task, 'value) cancellation =
  | Cancelled_sender of ('task, 'value) pending_sender
  | Cancelled_receiver of 'task pending_receiver
  | Not_blocked

let remove_first predicate items =
  let rec loop reversed = function
    | [] -> (None, List.rev reversed)
    | item :: rest when predicate item -> (Some item, List.rev_append reversed rest)
    | item :: rest -> loop (item :: reversed) rest
  in
  loop [] items

let cancel ~equal_task channel task =
  let sender, senders =
    remove_first (fun pending -> equal_task pending.sender task) channel.senders
  in
  match sender with
  | Some sender ->
      channel.senders <- senders;
      Cancelled_sender sender
  | None ->
      let receiver, receivers =
        remove_first (fun pending -> equal_task pending.receiver task) channel.receivers
      in
      channel.receivers <- receivers;
      Option.fold ~none:Not_blocked ~some:(fun receiver -> Cancelled_receiver receiver) receiver

type ('task, 'value) teardown = {
  dropped_values : 'value list;
  dropped_senders : ('task, 'value) pending_sender list;
  dropped_receivers : 'task pending_receiver list;
}

let teardown channel =
  if channel.torn_down then { dropped_values = []; dropped_senders = []; dropped_receivers = [] }
  else
    let dropped_values = channel.buffer in
    let dropped_senders = channel.senders in
    let dropped_receivers = channel.receivers in
    channel.closed <- true;
    channel.torn_down <- true;
    channel.buffer <- [];
    channel.senders <- [];
    channel.receivers <- [];
    { dropped_values; dropped_senders; dropped_receivers }

type view = {
  id : channel_id;
  capacity : int;
  closed : bool;
  buffered : int;
  waiting_senders : int;
  waiting_receivers : int;
}

let view (channel : (_, _) t) =
  {
    id = channel.id;
    capacity = channel.capacity;
    closed = channel.closed;
    buffered = List.length channel.buffer;
    waiting_senders = List.length channel.senders;
    waiting_receivers = List.length channel.receivers;
  }
