Exploration recording (EXP.1): `jacquard run --record LOG` writes an
owner-only exploration-log-v1 of every root-reaching operation and Dist choice,
with the source span of the application that performed it
(docs/exploration-log.md).

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cat > coin.jac <<'JACQUARD'
  > flip() = sample(Bernoulli(0.5))
  > 
  > report(b) = if b then print("heads\n") else print("tails\n")
  > 
  > report(flip())
  > JACQUARD

Recording changes nothing the run prints or returns.

  $ jacquard run coin.jac --allow console --allow dist --seed 3 > plain.out; echo "exit=$?"
  exit=0
  $ jacquard run coin.jac --allow console --allow dist --seed 3 --record coin.log > recorded.out; echo "exit=$?"
  exit=0
  $ cmp plain.out recorded.out && echo same-output
  same-output
  $ stat -c %a coin.log
  600
  $ cat coin.log
  jacquard-exploration-log format=1
  program source=29c1f7c0d493a4d92ed093198ab04adb7936d853c5f8e89d803895cfcde96eee core=0.3.0 prelude=000fd6c94590094253e7d1a86206744dfe4a3db827f1e7d0bfb332e1afebd985 engine=interpreter
  seed 3
  grants bytes=12
  console,dist
  policy 79a9df0ce6843b5804b1fd79693c0a31d9985ba0e7fd22e6cdc1483fb18a8b17 record-output=no
  step index=0 kind=choice operation=6a5da9e5bd03d63ee37665097c6cb472fde25578e7d8dbabf388a9f3a46a8a76 arguments=1
  name bytes=6
  sample
  site bytes=18
  coin.jac:1:10-1:32
  argument index=0 data bytes=79
  bernoulli#a1acd43fd2b30b2e47feb4d4137b98876a4c696c6b203598c3898ccf00600287(0.5)
  result data bytes=69
  true#bf5c9d86f11ef2591a2f1b7b9dcbc26342dcb093fce099341ce56e14b75482fb
  step index=1 kind=operation operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e arguments=1
  name bytes=5
  print
  site bytes=18
  coin.jac:3:23-3:39
  argument index=0 data bytes=9
  "heads\n"
  result data bytes=2
  ()
  end steps=2 exit=0

Sites name the user's source: `sample(...)` on line 1 and `print(...)` on
line 3.

  $ grep -A1 '^site' coin.log | grep -v '^--'
  site bytes=18
  coin.jac:1:10-1:32
  site bytes=18
  coin.jac:3:23-3:39

A recording never replaces a file, its bounds stop the run with a diagnostic
instead of truncating silently, and a policy decides what is kept.

  $ jacquard run coin.jac --allow console --allow dist --seed 3 --record coin.log > again.out 2>&1; echo "exit=$?"
  exit=1
  $ head -2 again.out
  error[E1016]: Exploration recording cannot proceed
    Cause: coin.log already exists
  $ jacquard run coin.jac --allow console --allow dist --seed 3 --record steps.log --max-steps 1 > steps.out 2>&1; echo "exit=$?"
  exit=2
  $ grep -o 'error\[E1016\].*' steps.out; grep 'Cause' steps.out
  error[E1016]: Exploration recording cannot proceed
    Cause: the recording reached --max-steps; the run was stopped
  $ tail -1 steps.log
  end steps=1 bounded=steps
  $ jacquard run coin.jac --allow console --allow dist --seed 3 --record bytes.log --max-bytes 10 > bytes.out 2>&1; echo "exit=$?"
  exit=2
  $ tail -1 bytes.log
  end steps=0 bounded=bytes
  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=none\nunlisted=ignore\noperations=0\n' > none.policy
  $ jacquard run coin.jac --allow console --allow dist --seed 3 --record quiet.log --record-policy none.policy > quiet.out; echo "exit=$?"
  exit=0
  $ tail -1 quiet.log
  end steps=0 exit=0

Secrets: a read secret is an unsupported field, and plaintext that
`secret.expose` returns is never recorded and is redacted from every later
field and output. Twenty random payloads never reach a log.

  $ cat > tok.jac <<'JACQUARD'
  > once effect Ship where {
  >   deploy : (Text) -> Bool
  > }
  > 
  > ship() = {
  >   let token = secret.read(secret-ref("deploy-token", None))
  >   let plain = secret.expose(token)
  >   print(plain)
  >   deploy(text.concat("bearer ", plain))
  > }
  > 
  > handle ship() { | return v -> v | deploy(t) resume k -> k(True) }
  > JACQUARD
  $ key=JACQUARD_SECRET_V0_$(printf deploy-token | od -An -tx1 | tr -d ' \n')_LATEST
  $ leaks=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do payload="p$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; rm -f s.log; env "$key=$payload" jacquard run tok.jac --allow secret --allow console --record s.log --record-output > s.out 2>&1 || echo "exit=$?"; n=$(grep -c -F "$payload" s.log); leaks=$((leaks + n)); done; echo "leaks=$leaks"
  leaks=0
  $ grep -c 'unsupported kind=secret' s.log
  3
  $ grep -c 'secret redacted' s.log
  2

Payloads that data-v1 escapes (quotes, backslashes, newlines) or that are not
ASCII are redacted in their escaped spelling too, and a policy that ignores
`secret.expose` results does not turn redaction off. Each payload carries a
fresh random marker, so a leak in any spelling shows up as the marker.

  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=none\nunlisted=record arguments=all result=ignore output=compare\noperations=0\n' > blind.policy
  $ leaks=0; for policy in default blind; do for i in 1 2 3 4 5; do for shape in quote newline unicode; do hex=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n'); case $shape in quote) payload="q\"$hex\\z";; newline) payload="$(printf 'n%s\nl' "$hex")";; unicode) payload="é$hex✓";; esac; rm -f s.log; extra=""; [ $policy = blind ] && extra="--record-policy blind.policy"; env "$key=$payload" jacquard run tok.jac --allow secret --allow console --record s.log --record-output $extra > s.out 2>&1 || echo "exit=$?"; n=$(grep -c -F "$hex" s.log); leaks=$((leaks + n)); done; done; done; echo "leaks=$leaks"
  leaks=0

Output keeps at most the policy's field limit and counts toward the byte
bound before it is retained; a recording policy must apply to the program; and
two identical definitions share one body, so their sites name whichever the
evaluator loaded first.

  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=8 interface=none\nunlisted=record arguments=all result=ignore output=compare\noperations=0\n' > small.policy
  $ printf 'print("0123456789abcdef")\n' > long.jac
  $ jacquard run long.jac --allow console --record long.log --record-output --record-policy small.policy > long.out; echo "exit=$?"
  exit=0
  $ grep -A1 '^output' long.log
  output truncated total=16 bytes=8
  01234567
  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=%064d\nunlisted=record arguments=all result=ignore output=compare\noperations=0\n' 0 > pinned.policy
  $ jacquard run coin.jac --allow console --allow dist --seed 3 --record pinned.log --record-policy pinned.policy > pinned.out 2>&1; echo "exit=$?"
  exit=1
  $ head -1 pinned.out; test -e pinned.log || echo no-log
  error[E1005]: The observation policy is invalid or refused.
  no-log
  $ printf 'first(n) = print(n)\n\nsecond(n) = print(n)\n\nsecond("x")\n' > twins.jac
  $ jacquard run twins.jac --allow console --record twins.log > twins.out; echo "exit=$?"
  exit=0
  $ grep -A1 '^site' twins.log
  site bytes=19
  twins.jac:3:13-3:21

A redacted field is bounded after redaction, so it never exceeds the policy's
field limit, and names and sites count toward the byte bound.

  $ env "$key=abcdefghi" jacquard run tok.jac --allow secret --allow console --record small-secret.log --record-policy small.policy > small-secret.out 2>&1; echo "exit=$?"
  exit=0
  $ grep -A1 '^argument' small-secret.log | grep -v '^--'
  argument index=0 truncated total=162 bytes=8
  secret-r
  argument index=0 unsupported kind=secret
  step index=2 kind=operation operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e arguments=1
  argument index=0 truncated total=19 bytes=8
  "<secret
  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=none\nunlisted=record arguments=none result=ignore output=ignore\noperations=0\n' > bare.policy
  $ jacquard run long.jac --allow console --record bare.log --record-policy bare.policy --max-bytes 64 > bare.out 2>&1; echo "exit=$?"
  exit=2
  $ tail -1 bare.log
  end steps=0 bounded=bytes

Grant names are recorded exactly as given, so a log recorded with any
`--allow` spelling still parses.

  $ jacquard run long.jac --allow CONSOLE --record upper.log > upper.out 2>&1; echo "exit=$?"
  exit=0
  $ grep -A1 '^grants' upper.log
  grants bytes=7
  CONSOLE

A choice that an inference driver captures has no single outcome; its kept
result is `missing`, as in OBS.1.

  $ printf 'dist.sample-lw(fn () -> sample(Bernoulli(0.5)), 1, 7)\n' > lw.jac
  $ jacquard run lw.jac --record lw.log > lw.out 2>&1; echo "exit=$?"
  exit=0
  $ grep -E '^(step|result)' lw.log | cut -d' ' -f1-2
  step index=0
  result missing

An operation whose argument projection runs out of fuel is still recorded,
with its arguments unfinished (the run then stops with E0919), and a kept
result is reserved against the byte bound when its step is admitted.

  $ printf 'print("%s")\n' "$(head -c 1024 /dev/zero | tr '\0' x)" > heavy.jac
  $ jacquard run heavy.jac --allow console --seed 7 --fuel 23 --record heavy.log > heavy.out 2>&1; echo "exit=$?"
  exit=2
  $ grep -E '^(step|argument|end)' heavy.log | cut -d' ' -f1-3
  step index=0 kind=operation
  argument index=0 unfinished
  end steps=1 exit=2
  $ jacquard run lw.jac --record lw-small.log --max-bytes 357 > lw-small.out 2>&1; echo "exit=$?"
  exit=2
  $ tail -1 lw-small.log
  end steps=0 bounded=bytes

A result whose projection runs out of fuel is recorded as unfinished, never
silently missing.

  $ printf '(read-line(), 1)\n' > reads.jac
  $ head -c 3000 /dev/zero | tr '\0' x > long-line.txt
  $ for fuel in 70 90 120; do rm -f reads.log; jacquard run reads.jac --allow console --seed 1 --fuel $fuel --record reads.log < long-line.txt > reads.out 2>&1 || true; grep '^result' reads.log | cut -d' ' -f1-2; done
  result unfinished
  result unfinished
  result unfinished

Output's line allowance counts toward the byte bound with its first chunk, and
a --record-policy needs a source that checks on its own.

  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=8 interface=none\nunlisted=record arguments=none result=ignore output=compare\noperations=0\n' > out-only.policy
  $ jacquard run long.jac --allow console --record out-only.log --record-output --record-policy out-only.policy --max-bytes 219 > out-only.out 2>&1; echo "exit=$?"
  exit=2
  $ tail -1 out-only.log
  end steps=1 bounded=bytes
  $ mkdir st && printf 'f(x) = add(x, 1)\n' > lib.jac && jacquard run lib.jac --store st > /dev/null; echo "exit=$?"
  exit=0
  $ printf 'f(1)\n' > use.jac
  $ jacquard run use.jac --store st --record st-default.log > st-default.out; echo "exit=$?"
  exit=0
  $ jacquard run use.jac --store st --record st-policy.log --record-policy none.policy > st-policy.out 2>&1; echo "exit=$?"
  exit=1
  $ head -2 st-policy.out
  error[E1005]: Observation policy is invalid or refused
    Cause: a --record-policy is validated against the source checked on its own, and this source does not check without its --store; record it with the default policy or make the source self-contained

A definition group that a persistent store already holds in another member
order still records the current source's sites.

  $ mkdir grp && printf 'first(n) = if eq(n, 0) then print("first") else second(sub(n, 1))\n\nsecond(n) = if eq(n, 0) then print("second") else first(sub(n, 1))\n' > before.jac
  $ jacquard run before.jac --store grp > /dev/null; echo "exit=$?"
  exit=0
  $ printf 'second(n) = if eq(n, 0) then print("second") else first(sub(n, 1))\n\nfirst(n) = if eq(n, 0) then print("first") else second(sub(n, 1))\n\nfirst(0)\n\nsecond(0)\n' > after.jac
  $ jacquard run after.jac --store grp --allow console --record grp.log > grp.out; echo "exit=$?"
  exit=0
  $ grep -A1 '^site' grp.log | grep -v '^--'
  site bytes=19
  after.jac:3:29-3:43
  site bytes=19
  after.jac:1:30-1:45

Group references inside live unquote splices are renumbered too, so a reordered
group whose members build quoted code by calling each other still records source
sites (each call crosses to the other member before it prints; print adds no
newline, so each result follows the printed name).

  $ mkdir qgrp && printf 'first(n) = if eq(n, 0) then { print("first"); quote { 1 } } else quote { unquote(second(sub(n, 1))) }\n\nsecond(n) = if eq(n, 0) then { print("second"); quote { 2 } } else quote { unquote(first(sub(n, 1))) }\n' > qbefore.jac
  $ jacquard run qbefore.jac --store qgrp > /dev/null; echo "exit=$?"
  exit=0
  $ printf 'second(n) = if eq(n, 0) then { print("second"); quote { 2 } } else quote { unquote(first(sub(n, 1))) }\n\nfirst(n) = if eq(n, 0) then { print("first"); quote { 1 } } else quote { unquote(second(sub(n, 1))) }\n\nfirst(1)\n\nsecond(1)\n' > qafter.jac
  $ jacquard run qafter.jac --store qgrp --allow console --record qgrp.log; echo "exit=$?"
  second(quote (lit 2))
  first(quote (lit 1))
  exit=0
  $ grep -A1 '^site' qgrp.log | grep -v '^--'
  site bytes=20
  qafter.jac:1:32-1:47
  site bytes=20
  qafter.jac:3:31-3:45

Named choices (EXP.2). `dist.named(name, d)` is exactly `sample(d)`: the
enumeration and likelihood-weighting drivers, a seeded root `dist` grant and
Warp see the same model.

  $ cat > named.jac <<'JAC'
  > model() = if dist.named("rain", Bernoulli(0.3)) then add(dist.named("die", UniformInt(1, 2)), 10) else dist.named("die", UniformInt(1, 3))
  > 
  > model()
  > JAC
  $ sed 's/dist.named("[a-z]*", \([^)]*)\))/sample(\1)/g' named.jac > unnamed.jac
  $ jacquard infer enumerate named.jac > named.enum; jacquard infer enumerate unnamed.jac | cmp - named.enum && echo same
  same
  $ jacquard infer lw named.jac --seed 5 --samples 200 > named.lw; jacquard infer lw unnamed.jac --seed 5 --samples 200 | cmp - named.lw && echo same
  same
  $ jacquard run named.jac --allow dist --seed 9 > named.run; jacquard run unnamed.jac --allow dist --seed 9 | cmp - named.run && echo same
  same
  $ cat > named-tests.jac <<'JAC'
  > named-model() = if dist.named("rain", Bernoulli(0.3)) then dist.named("die", UniformInt(1, 2)) else dist.named("die", UniformInt(1, 3))
  > 
  > sample-model() = if sample(Bernoulli(0.3)) then sample(UniformInt(1, 2)) else sample(UniformInt(1, 3))
  > 
  > same-posterior = case("enumerate sees the same model", fn () -> check.true(text.eq?(debug.inspect(dist.enumerate(named-model)), debug.inspect(dist.enumerate(sample-model))), "posterior"))
  > 
  > named-draws = prop("named draws", fn () -> { let x = dist.named("x", UniformInt(1, 6)); check.true(lt(0, x), "positive") })
  > JAC
  $ jacquard test named-tests.jac --seed 7 --no-cache
  PASS named-draws/named draws (prop: 100 cases, seed 7)
  PASS same-posterior/enumerate sees the same model (1 check)
  2 passed, 0 failed, 0 skipped, 0 refused

A recording names each draw (name, k), k counting earlier draws under that
name, at the dist.named call site; an unnamed sample keeps no name and is
addressed by its position. The output is the same as without --record.

  $ cat > dice.jac <<'JAC'
  > roll(n) = if eq(n, 0) then 0 else add(dist.named("die", UniformInt(1, 6)), roll(sub(n, 1)))
  > 
  > add(roll(2), sample(UniformInt(1, 6)))
  > JAC
  $ jacquard run dice.jac --allow dist --seed 3 > dice.plain
  $ jacquard run dice.jac --allow dist --seed 3 --record dice.log | cmp - dice.plain && echo same
  same
  $ grep -E '^(step|choice-name)' dice.log | cut -d' ' -f1-3
  step index=0 kind=choice
  choice-name draw=0 bytes=3
  step index=1 kind=choice
  choice-name draw=1 bytes=3
  step index=2 kind=choice
  $ grep -A1 '^site' dice.log | grep -v '^--'
  site bytes=18
  dice.jac:1:39-1:74
  site bytes=18
  dice.jac:1:39-1:74
  site bytes=18
  dice.jac:3:14-3:38

A choice an in-language driver handles never reaches the root, so it is not a
step and leaves no pending name behind for a later root draw.

  $ cat > inner.jac <<'JAC'
  > coin() = dist.named("coin", Bernoulli(0.5))
  > 
  > (dist.enumerate(coin), sample(Bernoulli(0.5)))
  > JAC
  $ jacquard run inner.jac --allow dist --seed 1 --record inner.log > /dev/null; echo "exit=$?"
  exit=0
  $ grep -c '^step' inner.log; grep -c '^choice-name' inner.log || true
  1
  0
