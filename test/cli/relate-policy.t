OBS.1: `jacquard relate --policy` compares runs under an observation policy
(docs/observation-policies.md). The verdict names the policy identity; the
comparison records observation-transcript-v1 instead of run-transcript-v1.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > receive-order.jac <<'EOF'
  > receive-order() =
  >   match channel.open(0) {
  >     | Ok(channel) -> {
  >         let first = async.spawn(fn () -> channel.send(channel, 1))
  >         let second = async.spawn(fn () -> channel.send(channel, 2))
  >         let left = channel.recv(channel)
  >         let right = channel.recv(channel)
  >         Ok((left, right, async.await(first), async.await(second)))
  >       }
  >     | Err(error) -> Err(error)
  >   }
  > 
  > receive-order()
  > EOF

The default policy compares results: the schedule-dependent result diverges in
run 3, and the diagnostic names the policy and the path. (Runs 1 and 2 only
fail to be provably equal: the spawned closures are unsupported values.)

  $ cat > default.policy <<'EOF'
  > jacquard-observation-policy format=1
  > result=compare field-bytes=4096 interface=none
  > unlisted=record arguments=all result=ignore output=compare
  > operations=0
  > EOF
  $ jacquard relate receive-order.jac --vary schedule=3 --seed 4 --policy default.policy; echo "exit $?"
  error[E1003]: Relational runs diverged
    Cause: Runs 1 and 3 diverged under observation policy a9e4cff5d4dd7a3176a3a77a6ce702b85a224f49b7deb7af171f46e88f505afc:
             at run[0].value:
               - "ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc((ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(2), ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(1), done#8bb29144a0570c1b4e6da9f9bb899b7938bb5eda078f5800a7acb24bb295a095(ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(())), done#8bb29144a0570c1b4e6da9f9bb899b7938bb5eda078f5800a7acb24bb295a095(ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(()))))"
               + "ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc((ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(1), ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(2), done#8bb29144a0570c1b4e6da9f9bb899b7938bb5eda078f5800a7acb24bb295a095(ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(())), done#8bb29144a0570c1b4e6da9f9bb899b7938bb5eda078f5800a7acb24bb295a095(ok#fc7e8018da11f1e0cc0c516bd50c27c8c3900881df816e50cb7881d8a2f490cc(()))))"
    Next step: Review the first divergence and make the result and routed effects invariant.
  exit 1

With only two runs, nothing certainly diverges, but the closures keep the runs
from being called equal.

  $ jacquard relate receive-order.jac --vary schedule=2 --seed 4 --policy default.policy; echo "exit $?"
  error[E1007]: Relational runs cannot be called equal
    Cause: Runs 1 and 2 cannot be called equal under observation policy a9e4cff5d4dd7a3176a3a77a6ce702b85a224f49b7deb7af171f46e88f505afc:
             at run[0].event[1].argument[0]:
               - <unsupported closure>
               + <unsupported closure>
    Next step: Raise the policy's field limit, compare coded failures, or compare runs that complete; an inconclusive field agrees only on a prefix, an opaque kind, or an unfinished projection.
  exit 1

A policy that ignores results and observes no operation finds the runs equal,
and the verdict carries its identity.

  $ cat > quiet.policy <<'EOF'
  > jacquard-observation-policy format=1
  > result=ignore field-bytes=4096 interface=none
  > unlisted=ignore
  > operations=0
  > EOF
  $ jacquard relate receive-order.jac --vary schedule=3 --seed 4 --policy quiet.policy; echo "exit $?"
  relate runs=3 seed=4 verdict=equal policy=c2f5c804fa2c329ec33faedbe6719beb3e8d84c72104a8cd9c95aa5e8bbc6cef
  exit 0

Policies are refused before anything runs: a malformed one, one naming an
operation the program does not have, and one pinned to another interface.

  $ printf 'jacquard-observation-policy format=2\n' > future.policy
  $ jacquard relate receive-order.jac --vary schedule=2 --seed 4 --policy future.policy; echo "exit $?"
  error[E1005]: The observation policy is invalid or refused.
    Cause: Invalid observation policy at byte offset 36: the policy format version is unsupported
    Next step: Write the policy in canonical observation-policy-v1 form and name only operations and an interface identity of the observed program.
  exit 1
  $ cat > stale.policy <<'EOF'
  > jacquard-observation-policy format=1
  > result=compare field-bytes=4096 interface=none
  > unlisted=ignore
  > operations=1
  > operation=0000000000000000000000000000000000000000000000000000000000000000 arguments=all result=compare output=ignore
  > EOF
  $ jacquard relate receive-order.jac --vary schedule=2 --seed 4 --policy stale.policy; echo "exit $?"
  error[E1005]: The observation policy is invalid or refused.
    Cause: The policy lists 0000000000000000000000000000000000000000000000000000000000000000, which is not an operation of the observed program.
    Next step: Write the policy in canonical observation-policy-v1 form and name only operations and an interface identity of the observed program.
  exit 1
  $ cat > pinned.policy <<'EOF'
  > jacquard-observation-policy format=1
  > result=compare field-bytes=4096 interface=0000000000000000000000000000000000000000000000000000000000000000
  > unlisted=ignore
  > operations=0
  > EOF
  $ jacquard relate receive-order.jac --vary schedule=2 --seed 4 --policy pinned.policy; echo "exit $?"
  error[E1005]: The observation policy is invalid or refused.
    Cause: The policy is pinned to interface 0000000000000000000000000000000000000000000000000000000000000000, but the observed program's interface is 41876cd2314ce448993f019bac3012626f506e242b9dffe8bdcb4207597ed05a.
    Next step: Write the policy in canonical observation-policy-v1 form and name only operations and an interface identity of the observed program.
  exit 1

Under a policy a runtime failure is an observation, not an abort: the failed
expression is recorded and the next one still runs (and still meets the
constituent's authority checks). A failure without a diagnostic code
cannot be told apart from another, so the runs are not called equal.

  $ cat > failing.jac <<'EOF'
  > div(1, 0)
  > add(1, 2)
  > EOF
  $ jacquard relate failing.jac --vary schedule=2 --seed 4 --policy default.policy; echo "exit $?"
  error[E1007]: Relational runs cannot be called equal
    Cause: Runs 1 and 2 cannot be called equal under observation policy a9e4cff5d4dd7a3176a3a77a6ce702b85a224f49b7deb7af171f46e88f505afc:
             at run[0].status:
               - failed uncoded
               + failed uncoded
    Next step: Raise the policy's field limit, compare coded failures, or compare runs that complete; an inconclusive field agrees only on a prefix, an opaque kind, or an unfinished projection.
  exit 1

A policy may name an operation the program itself declares: it is validated
against the prepared program, not only the prelude.

  $ cat > declares.jac <<'EOF'
  > once effect Probe where { probe.send : (Int) -> Int }
  > 
  > add(1, 2)
  > EOF
  $ send=$(jacquard hash declares.jac | awk '$1 == "0:probe.send" { print $2 }')
  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=none\nunlisted=ignore\noperations=1\noperation=%s arguments=all result=compare output=ignore\n' "$send" > declares.policy
  $ jacquard relate declares.jac --vary schedule=2 --seed 4 --policy declares.policy | sed 's/policy=[0-9a-f]*/policy=<identity>/'; echo "exit $?"
  relate runs=2 seed=4 verdict=equal policy=<identity>
  exit 0

Secret variation redacts payloads from diagnostics even when the policy's
field limit truncates them: no fragment of either payload survives.

  $ payload_a="rw-secret-v0-a-$(printf bdd732262feb6e95)"
  $ payload_b="rw-secret-v0-b-$(printf 28efe333b266f103)"
  $ cat > console-leak.jac <<'EOF'
  > leak() = {
  >   let token = secret.read(secret-ref("fixture", None))
  >   `op:print`(secret.expose(token))
  > }
  > leak()
  > EOF
  $ cat > truncating.policy <<'EOF'
  > jacquard-observation-policy format=1
  > result=compare field-bytes=30 interface=none
  > unlisted=record arguments=none result=ignore output=compare
  > operations=0
  > EOF
  $ jacquard relate console-leak.jac --vary secret=fixture --seed 42 --allow secret --allow console --policy truncating.policy > truncated.all 2>&1; echo "exit $?"
  exit 1
  $ cat truncated.all
  error[E1003]: Relational runs diverged
    Cause: Runs 1 and 2 diverged under observation policy 6f159581d046c190d07d5c8062c44c9e6d2c8d4bd1026995918cc27dfb5443f5:
             at run[0].event[2].output:
               - "<secret redacted>" (truncated from 31 bytes)
               + "<secret redacted>" (truncated from 31 bytes)
    Next step: Review the first divergence and make the result and routed effects invariant.
  $ for fragment in "$payload_a" "$payload_b" "${payload_a%?}" "${payload_b%?}" "${payload_a%????}"; do grep -F -c "$fragment" truncated.all || true; done
  0
  0
  0
  0
  0
  $ jacquard relate console-leak.jac --vary secret=fixture --seed 42 --allow secret --allow console --policy truncating.policy --diagnostic-format=json-v1 > truncated-json.all 2>&1; echo "exit $?"
  exit 1
  $ for fragment in "$payload_a" "$payload_b" "${payload_a%?}" "${payload_b%?}"; do grep -F -c "$fragment" truncated-json.all || true; done
  0
  0
  0
  0
