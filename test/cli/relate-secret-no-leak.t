Secret variation runs a shape-only reader twice with distinct injected latest
payloads. The exact payloads are assembled from pieces so neither complete
secret occurs in this committed transcript. All stdout and stderr are captured
before both payloads are searched.

  $ export JACQUARD_PRELUDE=../../prelude
  $ payload_a="rw-secret-v0-a-$(printf bdd732262feb6e95)"
  $ payload_b="rw-secret-v0-b-$(printf 28efe333b266f103)"
  $ cat > shape-only.jac <<'EOF'
  > token-shape() = {
  >   let token = secret.read(secret-ref("fixture", None))
  >   text.contains?(secret.expose(token), "rw-secret-v0-")
  > }
  > token-shape()
  > EOF
  $ jacquard relate shape-only.jac --vary secret=fixture --seed 42 --allow secret > no-leak.all 2>&1; status=$?
  $ cat no-leak.all
  relate runs=2 seed=42 verdict=equal
  $ echo "exit $status"
  exit 0
  $ count=$(grep -F -c "$payload_a" no-leak.all || true); echo "payload-a occurrences=$count"
  payload-a occurrences=0
  $ count=$(grep -F -c "$payload_b" no-leak.all || true); echo "payload-b occurrences=$count"
  payload-b occurrences=0
