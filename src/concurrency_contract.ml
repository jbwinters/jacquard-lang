exception Bug_invalid_task_id of string

let task_type_hash = "07791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb3"
let task_result_type_hash = "915f69bd6fd8b34c2794b4b0e7ca88f5aafd0187e5c7c36a59091f6d031405ae"
let async_effect_hash = "4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f"

let async_operation_hashes =
  [
    ("async.spawn", "dae95472328cdc4e38d64b3dd71f49f8b99d1cabbc5a1be603d7d44cc3b0c4a5");
    ("async.await", "7326d67de02f676afc476e7f16a3b4ee9617293865ffc8dd77ca7f0e9e8e675a");
    ("async.cancel", "5371011ae9b806265e1f12224cbb5a44bb6aabe7e5396e68eca7babf4c3a93d0");
    ("async.yield", "3f67a20859f53ca48578469efd2c4bc2956bfa6b37d241fcbf2fe19d1ddf3e6a");
  ]

type task_id = { scope_path : int list; spawn_index : int }

let task_id ~scope_path ~spawn_index =
  if scope_path = [] || List.hd scope_path <> 0 then
    raise (Bug_invalid_task_id "structured-concurrency task paths must start at root component 0");
  if List.exists (fun component -> component <= 0) (List.tl scope_path) then
    raise
      (Bug_invalid_task_id
         "structured-concurrency nested scope components must be one-based positive ordinals");
  if spawn_index < 0 then
    raise (Bug_invalid_task_id "structured-concurrency spawn indices must be non-negative");
  { scope_path; spawn_index }

let compare_task_id left right =
  match List.compare Int.compare left.scope_path right.scope_path with
  | 0 -> Int.compare left.spawn_index right.spawn_index
  | order -> order

let trace_task_id id =
  String.concat "/" (List.map string_of_int id.scope_path) ^ "#" ^ string_of_int id.spawn_index

type 'a task = task_id
type 'a task_result = Done of 'a | Failed of string | Cancelled
type lifecycle = Runnable | Suspended | Done_state | Failed_state | Cancelled_state
type failure_policy = Fail_fast | Collect
type 'a fail_fast_result = 'a list task_result
type 'a collect_result = 'a task_result list

type schemas = {
  spawn : string;
  await : string;
  cancel : string;
  yield : string;
  scope : string;
  scope_fail_fast : string;
  scope_collect : string;
}

let schemas =
  {
    spawn = "async.spawn:(()->{Async|e}a)->Task a";
    await = "async.await:(Task a)->TaskResult a";
    cancel = "async.cancel:(Task a)->()";
    yield = "async.yield:()->()";
    scope = "async.scope:(()->{Async|e}a)->{|e}TaskResult a";
    scope_fail_fast = "async.scope-fail-fast:(List (()->{Async|e}a))->{|e}TaskResult (List a)";
    scope_collect = "async.scope-collect:(List (()->{Async|e}a))->{|e}List (TaskResult a)";
  }

let default_failure_policy = Fail_fast

let valid_transition ~from_ ~into =
  match (from_, into) with
  | Runnable, (Suspended | Done_state | Failed_state | Cancelled_state)
  | Suspended, (Runnable | Done_state | Failed_state | Cancelled_state) ->
      true
  | _ -> false

let wake_waiters waiters = waiters

type 'a completion = { sequence : int; task : task_id; result : 'a task_result }

let compare_completion left right =
  match Int.compare left.sequence right.sequence with
  | 0 -> compare_task_id left.task right.task
  | order -> order

let order_completions completions = List.stable_sort compare_completion completions

let first_failure completions =
  order_completions completions
  |> List.find_opt (fun completion ->
      match completion.result with Done _ -> false | Failed _ | Cancelled -> true)

type wait_edge = { waiter : task_id; target : task_id }

let detect_wait_cycle edges =
  let rec drop count items =
    if count <= 0 then items else match items with [] -> [] | _ :: rest -> drop (count - 1) rest
  in
  let starts = edges |> List.map (fun edge -> edge.waiter) |> List.sort_uniq compare_task_id in
  let target_of waiter =
    edges
    |> List.filter (fun edge -> compare_task_id edge.waiter waiter = 0)
    |> List.sort (fun left right -> compare_task_id left.target right.target)
    |> function
    | [] -> None
    | edge :: _ -> Some edge.target
  in
  let rec walk path current =
    match List.find_index (fun prior -> compare_task_id prior current = 0) path with
    | Some index -> Some (drop index path @ [ current ])
    | None -> (
        match target_of current with
        | None -> None
        | Some target -> walk (path @ [ current ]) target)
  in
  List.find_map (walk []) starts

type cancellation_point = Await | Yield | Routed_effect

let cancellation_points = [ Await; Yield; Routed_effect ]
let task_escape_code = "E0907"

let task_escape_message =
  "a Task may not escape, outlive, or be used outside the structured scope that created it"

type decision = { sequence : int; runnable : task_id list; chosen : task_id }

let decide_round_robin ~sequence runnable =
  if sequence < 0 then
    raise (Bug_invalid_task_id "structured-concurrency decision sequences must be non-negative");
  match runnable with [] -> None | chosen :: _ -> Some { sequence; runnable; chosen }

let requeue_after_suspend ~runnable ~current = runnable @ [ current ]
let requeue_after_spawn ~runnable ~child ~parent = runnable @ [ child; parent ]
