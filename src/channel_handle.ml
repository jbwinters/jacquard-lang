type run = Concurrency_owner.t
type t = { run : run; id : Channel_contract.channel_id }

let diagnostic detail =
  Diag.error ~domain:Concurrency ~code:Concurrency_contract.task_escape_code
    ~summary:"This channel handle is outside its structured scope."
    ~cause:
      ("A ChannelHandle may not escape, outlive, or be used outside the structured scope that "
     ^ "opened it: " ^ detail)
    ~next_step:"Use the channel only inside the exact async.scope and evaluator run that opened it."
    ~contrast:None ()

let create ~run ~id = { run; id }

let checked_id (id : Channel_contract.channel_id) =
  match Channel_contract.channel_id ~scope_path:id.scope_path ~open_index:id.open_index with
  | checked -> Ok checked
  | exception Channel_contract.Bug_invalid_channel_id detail ->
      Error [ diagnostic ("malformed scheduler ID (" ^ detail ^ ")") ]

let validate_run ~run handle =
  Result.bind (checked_id handle.id) (fun id ->
      if Concurrency_owner.equal run handle.run then Ok id
      else Error [ diagnostic "the handle belongs to another run" ])

let validate_scope ~run ~scope_path handle =
  Result.bind (validate_run ~run handle) (fun id ->
      if id.scope_path = scope_path then Ok id
      else Error [ diagnostic "the handle belongs to another structured scope" ])
