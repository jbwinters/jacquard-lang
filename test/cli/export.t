DX.2 makes native build consume public surface input directly. It does not
create a bootstrap twin; explicit export is the evidence/debug boundary.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang
  $ cat > direct.jac <<'JACQUARD'
  > answer = 42
  > answer
  > JACQUARD
  $ jacquard build direct.jac -o direct-native > /dev/null
  $ test ! -e direct.jqd && echo no-implicit-twin
  no-implicit-twin
  $ jacquard export direct.jac -o explicit.jqd
  $ jacquard build explicit.jqd -o exported-native > /dev/null
  $ ./direct-native > direct.out 2>&1
  $ ./exported-native > exported.out 2>&1
  $ cmp direct.out exported.out && cat direct.out
  42
The command and top-level help state the explicit workflow.

  $ jacquard --help=plain | grep '^       export '
         export --output=OUT [--prelude=DIR] [--syntax=SYNTAX] [OPTION]…
  $ jacquard export --help=plain | grep 'atomically and never replaces'
         atomically and never replaces an existing path.

Repeated exports are byte-identical and reparsed member hashes equal the
surface hashes across quote-heavy, handler/effect, Dist, recursive, and
Preflight-shaped programs.

  $ for spec in quote:../../demos/tooling/repair.jac handler:../../demos/basics/m1-choose.jac dist:../../demos/inference/m3-two-coins.jac recursive:../../demos/basics/m1-fact.jac preflight:../../demos/worlds/preflight.jac; do
  >   label=${spec%%:*}; source=${spec#*:}
  >   jacquard export "$source" -o "$label-a.jqd"
  >   jacquard export "$source" -o "$label-b.jqd"
  >   cmp "$label-a.jqd" "$label-b.jqd"
  >   jacquard hash "$source" > "$label-surface.hash"
  >   jacquard hash "$label-a.jqd" > "$label-bootstrap.hash"
  >   cmp "$label-surface.hash" "$label-bootstrap.hash"
  >   echo "equivalent: $label"
  > done
  equivalent: quote
  equivalent: handler
  equivalent: dist
  equivalent: recursive
  equivalent: preflight

Quote constructor and operation namespace intent remains structural in the
metadata-free carrier, including nested constructor use.

  $ cat > namespace-quote.jac <<'JACQUARD'
  > quote { (Some(1), `op:sample`(Bernoulli(0.5))) }
  > JACQUARD
  $ jacquard export namespace-quote.jac -o namespace-quote.jqd
  $ grep -o 'surface-ref-v0 [a-z]* [a-z]*' namespace-quote.jqd
  surface-ref-v0 con some
  surface-ref-v0 op sample
  surface-ref-v0 con bernoulli
  $ jacquard hash namespace-quote.jac > namespace-surface.hash
  $ jacquard hash namespace-quote.jqd > namespace-bootstrap.hash
  $ cmp namespace-surface.hash namespace-bootstrap.hash && echo same-quote-hash
  same-quote-hash

Mutually recursive definitions export as one resolved SCC and retain every
member hash.

  $ cat > mutual.jac <<'JACQUARD'
  > even(n) = if eq(n, 0) then True else odd(sub(n, 1))
  > odd(n) = if eq(n, 0) then False else even(sub(n, 1))
  > even(10)
  > JACQUARD
  $ jacquard export mutual.jac -o mutual.jqd
  $ grep -o '(groupref [01])' mutual.jqd | sort -u
  (groupref 0)
  (groupref 1)
  $ jacquard hash mutual.jac > mutual-surface.hash
  $ jacquard hash mutual.jqd > mutual-bootstrap.hash
  $ cmp mutual-surface.hash mutual-bootstrap.hash && echo same-scc-hashes
  same-scc-hashes

Direct surface and explicitly exported native programs have identical stdout,
stderr, and exit status across quote/code data, a deep multi-shot handler, Dist,
and a mutually recursive SCC. The Task 74 differential harness independently
checks each carrier against the interpreter.

  $ cat > native-dist.jac <<'JACQUARD'
  > dist.enumerate(fn () -> `op:sample`(Bernoulli(0.5)))
  > JACQUARD
  $ jacquard export native-dist.jac -o native-dist.jqd
  $ for spec in quote:namespace-quote.jac:namespace-quote.jqd handler:../../demos/basics/m1-choose.jac:handler-a.jqd dist:native-dist.jac:native-dist.jqd recursive:mutual.jac:mutual.jqd; do
  >   label=${spec%%:*}; rest=${spec#*:}; surface=${rest%%:*}; bootstrap=${rest#*:}
  >   jacquard build "$surface" -o "$label-surface-native" > /dev/null
  >   jacquard build "$bootstrap" -o "$label-bootstrap-native" > /dev/null
  >   ./$label-surface-native > "$label-surface.stdout" 2> "$label-surface.stderr"; surface_status=$?
  >   ./$label-bootstrap-native > "$label-bootstrap.stdout" 2> "$label-bootstrap.stderr"; bootstrap_status=$?
  >   cmp "$label-surface.stdout" "$label-bootstrap.stdout"
  >   cmp "$label-surface.stderr" "$label-bootstrap.stderr"
  >   test "$surface_status" = "$bootstrap_status"
  >   echo "native carrier parity: $label (exit $surface_status)"
  > done
  native carrier parity: quote (exit 0)
  native carrier parity: handler (exit 0)
  native carrier parity: dist (exit 0)
  native carrier parity: recursive (exit 0)
  $ JACQUARD=jacquard ../../scripts/native-diff.sh namespace-quote.jac namespace-quote.jqd ../../demos/basics/m1-choose.jac handler-a.jqd native-dist.jac native-dist.jqd mutual.jac mutual.jqd
  native-diff: 8 identical, 0 manifested refusals, 0 failures
  native-diff: PASS

The product Preflight fixture is currently outside native-v1 eligibility
(`text.contains?` and dynamic eval). Both carriers refuse byte-identically on
stdout, stderr, and exit rather than diverging or silently compiling one side.

  $ jacquard build ../../demos/worlds/preflight.jac -o preflight-surface-native > preflight-surface.build.stdout 2> preflight-surface.build.stderr; surface_status=$?
  $ jacquard build preflight-a.jqd -o preflight-bootstrap-native > preflight-bootstrap.build.stdout 2> preflight-bootstrap.build.stderr; bootstrap_status=$?
  $ cmp preflight-surface.build.stdout preflight-bootstrap.build.stdout
  $ cmp preflight-surface.build.stderr preflight-bootstrap.build.stderr
  $ test "$surface_status" = "$bootstrap_status" && echo "native carrier refusal parity: preflight (exit $surface_status)"
  native carrier refusal parity: preflight (exit 1)
  $ cat preflight-surface.build.stderr
  error[E1101]: not yet compilable in native v1: live-policy builtin `text.contains?` is not yet implemented natively
  error[E1102]: run-plan uses eval, which requires the interpreter tier

Comments, documentation, formatting, and their spans are intentionally erased;
the exported structure retains the semantic hash rather than source fidelity.

  $ cat > trivia.jac <<'JACQUARD'
  > -- confidential source comment
  > --| public source documentation
  > answer   =   add(
  >   40,
  >   2)
  > answer
  > JACQUARD
  $ jacquard export trivia.jac -o trivia.jqd
  $ grep -E 'confidential|documentation' trivia.jqd || echo metadata-erased
  metadata-erased
  $ jacquard hash trivia.jac > trivia-surface.hash
  $ jacquard hash trivia.jqd > trivia-bootstrap.hash
  $ cmp trivia-surface.hash trivia-bootstrap.hash && echo same-semantic-hash
  same-semantic-hash

An existing output is a stable collision and is never truncated.

  $ printf 'sentinel\n' > occupied.jqd
  $ jacquard export direct.jac -o occupied.jqd
  error[E1301]: export output occupied.jqd already exists; choose a new path or remove it explicitly
  [1]
  $ cat occupied.jqd
  sentinel

Malformed and unresolved input fail before publication. Surface failures retain
their spans and resolution retains suggestions.

  $ printf 'answer = @\n' > malformed.jac
  $ jacquard export malformed.jac -o malformed.jqd
  malformed.jac:1:10-11: error[E1210]: unexpected surface character `@`
  [1]
  $ test ! -e malformed.jqd && echo no-partial-malformed
  no-partial-malformed
  $ printf 'ad(1, 2)\n' > unresolved.jac
  $ jacquard export unresolved.jac -o unresolved.jqd > unresolved.err 2>&1; status=$?; grep -E 'error\[E0301\]|hint: did you mean' unresolved.err; echo "exit:$status"
  unresolved.jac:1:1-3: error[E0301]: unknown name `ad`
    hint: did you mean one of: add, eq, fs?
  exit:1
  $ test ! -e unresolved.jqd && echo no-partial-unresolved
  no-partial-unresolved

Stdin and non-seekable artifacts are refused before reading. Callers must
materialize them so syntax and resolution have a named source boundary.

  $ printf '1\n' | jacquard export - -o stdin.jqd
  error[E1302]: jacquard export requires a named regular input file; materialize stdin first
  [1]
  $ mkfifo source.fifo
  $ jacquard export source.fifo -o fifo.jqd
  error[E1302]: export input source.fifo is not a regular seekable file; materialize the source first
  [1]

An atomic-publication failure is actionable and leaves no destination or
same-directory temporary artifact.

  $ jacquard export direct.jac -o missing/out.jqd > atomic.err 2>&1; status=$?; grep 'error\[E1303\]: cannot publish export atomically' atomic.err | sed -E 's/tmp-[0-9]+-0/tmp-PID-0/'; echo "exit:$status"
  error[E1303]: cannot publish export atomically: missing/out.jqd: No such file or directory (open, missing/.out.jqd.tmp-PID-0)
  exit:1
  $ test ! -e missing/out.jqd && test -z "$(find . -maxdepth 1 -name '.out.jqd.tmp-*' -print)" && echo no-partial-atomic
  no-partial-atomic
