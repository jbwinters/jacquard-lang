make-call(argument) = quote { add(unquote(argument), 1) }

candidate = quote { fn (x) -> add(x, 1) }

run-candidate() = {
  let function = `op:eval-code`(candidate)
  function(41)
}
