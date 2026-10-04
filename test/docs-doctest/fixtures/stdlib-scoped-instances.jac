state.scoped(10, fn (outer) ->
  state.scoped(20, fn (inner) -> {
    state.put-at(outer, 11)
    (state.get-at(outer), state.get-at(inner))
  }))
