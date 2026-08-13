Secret variation must compare raw payloads but redact them only at the final
presentation boundary. A Console leak therefore diverges even though both
rendered sides show the same marker. Runtime errors and JSON diagnostics use
the same scrubber. Every command captures both streams and leak-scans the two
exact concatenation-built payloads.

  $ export JACQUARD_PRELUDE=../../prelude
  $ payload_a="rw-secret-v0-a-$(printf bdd732262feb6e95)"
  $ payload_b="rw-secret-v0-b-$(printf 28efe333b266f103)"
  $ cat > console-leak.jac <<'EOF'
  > leak() = {
  >   let token = secret.read(secret-ref("fixture", None))
  >   `op:print`(secret.expose(token))
  > }
  > leak()
  > EOF
  $ jacquard relate console-leak.jac --vary secret=fixture --seed 42 --allow secret --allow console > leak.all 2>&1; status=$?
  $ cat leak.all
  error[E1003]: Relational runs diverged
    Cause: Runs 1 and 2 diverged with trace-divergence:
             at observation[0].trace[2]:
               - operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e output="<secret redacted>"
               + operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e output="<secret redacted>"
    Next step: Review the first divergence and make the result and routed effects invariant.
  $ echo "exit $status"
  exit 1
  $ count=$(grep -F -c "$payload_a" leak.all || true); echo "payload-a occurrences=$count"
  payload-a occurrences=0
  $ count=$(grep -F -c "$payload_b" leak.all || true); echo "payload-b occurrences=$count"
  payload-b occurrences=0

  $ jacquard relate console-leak.jac --vary secret=fixture --seed 42 --allow secret --allow console --diagnostic-format=json-v1 > leak-json.all 2>&1; status=$?
  $ cat leak-json.all
  {"schema":"jacquard-diagnostic-v1","domain":"warp","code":"E1003","severity":"error","span":null,"summary":"Relational runs diverged","cause":"Runs 1 and 2 diverged with trace-divergence:\n  at observation[0].trace[2]:\n    - operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e output=\"<secret redacted>\"\n    + operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e output=\"<secret redacted>\"","next_step":"Review the first divergence and make the result and routed effects invariant."}
  $ echo "json exit $status"
  json exit 1
  $ count=$(grep -F -c "$payload_a" leak-json.all || true); echo "json payload-a occurrences=$count"
  json payload-a occurrences=0
  $ count=$(grep -F -c "$payload_b" leak-json.all || true); echo "json payload-b occurrences=$count"
  json payload-b occurrences=0

  $ cat > runtime-leak.jac <<'EOF'
  > fail() = {
  >   let token = secret.read(secret-ref("fixture", None))
  >   `op:read`(secret.expose(token))
  > }
  > fail()
  > EOF
  $ jacquard relate runtime-leak.jac --vary secret=fixture --seed 42 --allow secret --allow fs > runtime.all 2>&1; status=$?
  $ cat runtime.all
  error: World-effect I/O failed
    Cause: io error: <secret redacted>: No such file or directory
    Next step: Correct the path, permissions, or external resource and try again.
  $ echo "runtime exit $status"
  runtime exit 2
  $ count=$(grep -F -c "$payload_a" runtime.all || true); echo "runtime payload-a occurrences=$count"
  runtime payload-a occurrences=0
  $ count=$(grep -F -c "$payload_b" runtime.all || true); echo "runtime payload-b occurrences=$count"
  runtime payload-b occurrences=0
