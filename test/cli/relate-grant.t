RW.5 varies one selected root grant against the released dry world. The
comparison deliberately projects away routed calls and audits: a Net request
whose response is discarded therefore has the same answer in both worlds.
Grant names are case-insensitive.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > response-independent.jac <<'EOF'
  > {
  >   let _ = fetch(MkRequest("https://example.test/ignored", ""))
  >   "answer"
  > }
  > EOF
  $ jacquard relate response-independent.jac --vary grant=NeT --seed 42
  relate runs=2 seed=42 verdict=equal

The same live and dry handlers are observably different when the response body
is returned. The live result is always the minus side and the dry result is the
plus side; no routed-event identity or audit content appears in E1003.

  $ cat > response-dependent.jac <<'EOF'
  > match fetch(MkRequest("https://example.test/result", "")) {
  >   | MkResponse(_, body) -> body
  > }
  > EOF
  $ jacquard relate response-dependent.jac --vary grant=net --seed 42 > divergent.out 2> divergent.err; status=$?; wc -c < divergent.out; cat divergent.err; echo "exit $status"
  0
  error[E1003]: Relational runs diverged
    Cause: Runs 1 and 2 diverged with value-divergence:
             at observation[0].value:
               - "\"<stub response for https://example.test/result>\"\n"
               + "\"<dry-run response>\"\n"
    Next step: Review the first divergence and make the rendered result values invariant. Routed effects and audits are outside this comparison.
  exit 1
  $ grep -Ec 'trace-events=|operation=[0-9a-f]{64}|fetched https://' divergent.err
  0
  [1]

The other admitted answer-bearing handlers are executable too. Infer exposes
its live/dry answer difference, while a deterministic Dist value can agree
across its distinct live-seed and dry-seed samplers.

  $ cat > infer-dependent.jqd <<'EOF'
  > (app (var complete) (app (var mk-prompt) (lit "question") (var none)))
  > EOF
  $ jacquard relate infer-dependent.jqd --vary grant=infer --seed 42 2>&1 | grep -E 'Runs 1 and 2|stub completion|dry-run completion'
    Cause: Runs 1 and 2 diverged with value-divergence:
               - "\"<stub completion for: question>\"\n"
               + "\"<dry-run completion>\"\n"
  $ echo '(app (var sample) (app (var bernoulli) (lit 1.0)))' > fixed-dist.jqd
  $ jacquard relate fixed-dist.jqd --vary grant=dist --seed 42
  relate runs=2 seed=42 verdict=equal

Write-shaped or forwarded/mixed effects are refused before execution.
Dist seed zero and every extra --allow are likewise usage errors, preserving a
single selected live authority and distinct sampler worlds.

  $ jacquard relate response-independent.jac --vary grant=fs --seed 42
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: option '--vary': grant=fs is refused: Fs mixes forwarded reads with
            audited mutation
  [124]
  $ jacquard relate response-independent.jac --vary grant=dist --seed 0
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: grant=dist requires a nonzero --seed so the live sampler differs
            from the dry seed-0 sampler
  [124]
  $ jacquard relate response-independent.jac --vary grant=net --seed 42 --allow net
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: grant variation does not accept --allow; the selected grant is the
            only live root authority
  [124]
  $ jacquard relate response-independent.jac --vary grant=unknown --seed 42
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: option '--vary': expected schedule=N with N > 0, secret=NAME, or
            grant=net|infer|dist
  [124]
