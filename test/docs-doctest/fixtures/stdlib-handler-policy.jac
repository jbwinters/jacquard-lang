effect Approval where {
  ask : (Text) -> Bool
}

approve-and-run(workflow) =
  handle workflow() {
    | return result -> Some(result)
    | ask(prompt) resume continue -> continue(True)
  }

approve-and-run(fn () -> if ask("ship?") then 42 else 0)
