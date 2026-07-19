type run = Concurrency_owner.t
type t = { run : run; scope_path : int list; spawn_index : int }

let create_run = Concurrency_owner.create

let diagnostic detail =
  Diag.error ~domain:Concurrency ~code:Concurrency_contract.task_escape_code
    ~summary:"This task handle is outside its structured scope."
    ~cause:(Concurrency_contract.task_escape_message ^ ": " ^ detail)
    ~next_step:
      "Use the handle only with async.await or async.cancel inside its creating structured scope."
    ~contrast:None ()

let checked_id scope_path spawn_index =
  match Concurrency_contract.task_id ~scope_path ~spawn_index with
  | id -> Ok id
  | exception Concurrency_contract.Bug_invalid_task_id detail ->
      Error [ diagnostic ("malformed scheduler ID (" ^ detail ^ ")") ]

let create ~run ~scope_path ~spawn_index =
  Result.map (fun _ -> { run; scope_path; spawn_index }) (checked_id scope_path spawn_index)

let validate_run ~run handle =
  Result.bind (checked_id handle.scope_path handle.spawn_index) (fun id ->
      if Concurrency_owner.equal handle.run run then Ok id
      else Error [ diagnostic "the handle belongs to another run" ])

let validate_scope ~run ~scope_path handle =
  Result.bind (validate_run ~run handle) (fun id ->
      if id.scope_path = scope_path then Ok id
      else Error [ diagnostic "the handle belongs to another structured scope" ])
