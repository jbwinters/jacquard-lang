governance-check-workspace-v0(outer-policy, inner-policy, simulators) =
  governance.with-sequence(fn (sequence) ->
    workspace.live-layer(sequence, outer-policy, simulators, fn () ->
      workspace.forward-layer(sequence, inner-policy, simulators, fn () -> "verified")))
