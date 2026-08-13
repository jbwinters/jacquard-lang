RW.3 compares each complete run with run 1. This rendezvous fixture makes its
result contain both receive order and child-completion results. Root seed 4 and
its first derived schedule agree, while the second derived schedule deliberately
disagrees. E1003 therefore proves compare-all-to-baseline order, one-based run
indices, and the canonical zero-based RW.2 frame for the second top-level result.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > receive-order.jac <<'EOF'
  > receive-order() =
  >   match channel.open(0) {
  >     | Ok(channel) -> {
  >         let first = async.spawn(fn () -> channel.send(channel, 1))
  >         let second = async.spawn(fn () -> channel.send(channel, 2))
  >         -- Deliberately schedule-dependent: the returned pair embeds child send/completion order.
  >         let left = channel.recv(channel)
  >         let right = channel.recv(channel)
  >         Ok((left, right, async.await(first), async.await(second)))
  >       }
  >     | Err(error) -> Err(error)
  >   }
  > 
  > 0
  > receive-order()
  > EOF
  $ jacquard relate receive-order.jac --vary schedule=3 --seed 4 > divergence.out 2> divergence.err; exit_code=$?; wc -c < divergence.out; cat divergence.err; echo "exit $exit_code"
  0
  error[E1003]: Relational runs diverged
    Cause: Runs 1 and 3 diverged with value-divergence:
             at observation[1].value:
               - "ok((ok(2), ok(1), done(ok(())), done(ok(()))))\n"
               + "ok((ok(1), ok(2), done(ok(())), done(ok(()))))\n"
    Next step: Review the first divergence and make the result and routed effects invariant.
  exit 1

The structured diagnostic renderer keeps the same divergence in one JSON-v1
object on stderr, with stdout empty.

  $ jacquard relate receive-order.jac --vary schedule=3 --seed 4 --diagnostic-format=json-v1 > divergence-json.out 2> divergence-json.err; exit_code=$?; wc -c < divergence-json.out; cat divergence-json.err; echo "exit $exit_code"
  0
  {"schema":"jacquard-diagnostic-v1","domain":"warp","code":"E1003","severity":"error","span":null,"summary":"Relational runs diverged","cause":"Runs 1 and 3 diverged with value-divergence:\n  at observation[1].value:\n    - \"ok((ok(2), ok(1), done(ok(())), done(ok(()))))\\n\"\n    + \"ok((ok(1), ok(2), done(ok(())), done(ok(()))))\\n\"","next_step":"Review the first divergence and make the result and routed effects invariant."}
  exit 1
