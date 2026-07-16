build-preflight(plan-code, threshold-code) =
  quote {
    fn (telemetry) ->
      match unquote(plan-code) {
        | Ship ->
            if int.gt?(telemetry, unquote(threshold-code)) then
              quote { `op:net.request`("release") }
            else
              quote { Hold }
        | Hold -> quote { Hold }
      }
  }
