type run = Concurrency_owner.t
type t = { run : run; id : Channel_contract.channel_id }

let diagnostic detail =
  Diag.error ~code:Concurrency_contract.task_escape_code
    ~hint:"use the channel only inside the exact async.scope and evaluator run that opened it"
    ("a ChannelHandle may not escape, outlive, or be used outside the structured scope that opened \
      it: " ^ detail)

let create ~run ~id = { run; id }

let validate_run ~run handle =
  if Concurrency_owner.equal run handle.run then Ok handle.id
  else Error [ diagnostic "the handle belongs to another run" ]

let validate_scope ~run ~scope_path handle =
  Result.bind (validate_run ~run handle) (fun id ->
      if id.scope_path = scope_path then Ok id
      else Error [ diagnostic "the handle belongs to another structured scope" ])
