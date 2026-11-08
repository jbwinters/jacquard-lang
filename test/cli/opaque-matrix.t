Opaque types across native dependency calls and relational comparison (TYPE.2,
docs/designs/abstract-types.md §2.4). A root without a namespace may rebind
prelude term names; its dependency still calls the prelude's own declarations,
and the native binary prints exactly what the interpreter prints. A root that
runs an entry may not rebind a prelude constructor name (E1731), with or without
a dependency: the root's own constructors are checked against the prelude's.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude JACQUARD_RUNTIME=$PWD/../../runtime CC=clang
  $ export TMPDIR=$PWD
  $ mkdir -p work/lib work/app && cd work && mkdir .git
  $ cat > lib/project.jqd <<'M'
  > (project-v1 (name "lib") (requires (core "0.2")) (namespace lib) (units "lib.jac")
  >   (exports (term lib.check) (term lib.flags) (term lib.parse)))
  > M
  $ cat > lib/lib.jac <<'S'
  > lib.check(r) = if real.between?(r, 0.0, 1.0) then Ok(r) else Err("out of range")
  > lib.flags() = support(bernoulli(0.5))
  > lib.parse(t) = hash.parse(t)
  > S
  $ cat > app/project.jqd <<'M'
  > (project-v1 (name "app") (requires (core "0.2")) (units "app.jac")
  >   (deps (dep (as lib) (path "../lib")))
  >   (entries (run demo (units "demo.jac") (grants console) (native))))
  > M
  $ cat > app/app.jac <<'S'
  > opaque type Coin = | Heads | Tails
  > real.between?(r, a, b) = false
  > support(d) = [(Heads, 1.0)]
  > hash.parse(t) = Err("rebound")
  > S
  $ cat > app/demo.jac <<'S'
  > debug.inspect((lib.check(0.5), lib.check(2.0), lib.flags(), lib.parse("zz"), support(bernoulli(0.5)), Heads))
  > S
  $ jacquard project pin --project app > /dev/null
  $ jacquard project run --project app demo --allow console > run.out 2>&1; echo $?
  0
  $ jacquard project build --project app demo -o app-native > /dev/null 2>&1; echo $?
  0
  $ ./app-native --allow console > native.out 2>&1; echo $?
  0
  $ cmp run.out native.out && cat run.out
  "(ok(0.5), err(\"out of range\"), cons(mk-pair(true, 0.5), cons(mk-pair(false, 0.5), nil)), err(\"expected 64 lowercase hexadecimal HASH_V0 digits\"), cons((<opaque coin>, 1.0), nil), <opaque coin>)"
  $ printf 'opaque type Bool = | False | True\nopaque type Result = | Ok | Err\n' > app/app.jac
  $ jacquard project run --project app demo --allow console > clash.out 2>&1; echo $?
  1
  $ grep -c 'error\[E1731\]' clash.out
  4
  $ grep -o 'constructor `[a-z]*` of type `[a-z]*` of the library and constructor `[a-z]*` of type `[a-z]*` of the prelude' clash.out | sort
  constructor `err` of type `result` of the library and constructor `err` of type `result` of the prelude
  constructor `false` of type `bool` of the library and constructor `false` of type `bool` of the prelude
  constructor `ok` of type `result` of the library and constructor `ok` of type `result` of the prelude
  constructor `true` of type `bool` of the library and constructor `true` of type `bool` of the prelude
  $ mkdir solo && cp app/app.jac solo/app.jac && echo 'True' > solo/demo.jac
  $ cat > solo/project.jqd <<'M'
  > (project-v1 (name "solo") (requires (core "0.2")) (units "app.jac")
  >   (entries (run demo (units "demo.jac") (grants console))))
  > M
  $ jacquard project run --project solo demo --allow console > solo.out 2>&1; echo $?
  1
  $ grep -c 'error\[E1731\]' solo.out
  4
  $ cd ..

Relational comparison keys opaque values by structure. Under grant=dist the live
and dry samplers draw the same coin for seed 1 and different coins for seed 3,
as they do for the same draw over Ints, so the comparison neither merges
distinct opaque results nor separates equal ones. Without a policy `relate`
records run-transcript-v1, whose divergence messages show a value's structure,
outside the display guarantee (§2.4). An observation policy maps an opaque value
to the unsupported opaque kind, so it cannot call runs equal, while the same
policy compares the Int draw.

  $ cat > coin.jqd <<'EOF_JQD'
  > (deftype coin () (opaque) (con heads) (con tails))
  > (app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (var heads) (lit 0.5)) (app (var cons) (app (var mk-pair) (var tails) (lit 0.5)) (var nil)))))
  > EOF_JQD
  $ sed -e 's/(var heads)/(lit 1)/' -e 's/(var tails)/(lit 2)/' -e '1d' coin.jqd > int.jqd
  $ jacquard relate int.jqd --vary grant=dist --seed 1
  relate runs=2 seed=1 verdict=equal
  $ jacquard relate coin.jqd --vary grant=dist --seed 1
  relate runs=2 seed=1 verdict=equal
  $ jacquard relate int.jqd --vary grant=dist --seed 3 > int3.out 2>&1; echo "exit $?"; grep -c 'E1003' int3.out
  exit 1
  1
  $ jacquard relate coin.jqd --vary grant=dist --seed 3
  error[E1003]: Relational runs diverged
    Cause: Runs 1 and 2 diverged with value-divergence:
             at observation[0].value:
               - "heads\n"
               + "tails\n"
    Next step: Review the first divergence and make the rendered result values invariant. Routed effects and audits are outside this comparison.
  [1]
  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=none\nunlisted=record arguments=all result=ignore output=compare\noperations=0\n' > result.policy
  $ for s in 1 3; do jacquard relate int.jqd --vary grant=dist --seed $s --policy result.policy > int.out 2>&1; echo "exit $?"; grep -o -e 'verdict=equal' -e 'error\[E[0-9]*\]' int.out; done
  exit 0
  verdict=equal
  exit 1
  error[E1003]
  $ for s in 1 3; do jacquard relate coin.jqd --vary grant=dist --seed $s --policy result.policy > coin.out 2>&1; echo "exit $?"; grep -e 'error\[' -e 'unsupported' coin.out; done
  exit 1
  error[E1007]: Relational runs cannot be called equal
               - <unsupported opaque>
               + <unsupported opaque>
  exit 1
  error[E1007]: Relational runs cannot be called equal
               - <unsupported opaque>
               + <unsupported opaque>

The two native twins' interpreter output is pinned here, so a change that both
engines share still shows: g54's builtins and governance validation return
prelude values beside the rebound opaque names, and g55's enumeration keeps two
opaque outcomes, each nested driver keeps two, and `pmf` finds 0.7.

  $ jacquard run ../../test/native-gauntlet/g54-opaque-rebound-prelude.jqd
  (<opaque bool>, <opaque result>, <opaque list>, <opaque pair>)
  (ok(cons(governance-effect(#be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45), cons(governance-effect(#6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31), nil))), err("invalid Authority: entries must be in strict canonical order without duplicates"), ok(cons(governance-effect(#40bc4343fb2b4bcc18b18f63f7bb68675b746751bb40b876072e622046a81372), cons(governance-effect(#6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31), nil))), err("invalid Authority: entries must be in strict canonical order without duplicates"), ok(cons(governance-effect(#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa), cons(governance-effect(#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb), nil))), err("invalid Authority: entries must be in strict canonical order without duplicates"), ok(cons(governance-effect(#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa), cons(governance-resource(#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, "a", #aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa), cons(governance-resource(#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, "a", #bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb), cons(governance-resource(#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, "a:", #aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa), cons(governance-resource(#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, "a::", #aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa), cons(governance-effect(#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb), nil))))))), err("invalid Authority: entries must be in strict canonical order without duplicates"), err("invalid Authority: entries must be in strict canonical order without duplicates"), err("invalid Authority: entries must be in strict canonical order without duplicates"))
  ok(inference-posterior-v1(cons(mk-pair(false, 0.25), cons(mk-pair(true, 0.25), cons(mk-pair(true, 0.25), cons(mk-pair(true, 0.25), nil)))), inference-metadata-v1(inference-likelihood-weighting-v1, false, some(3), 4, 4)))
  cons(mk-pair(true, 0.5), cons(mk-pair(false, 0.5), nil))
  $ jacquard run ../../test/native-gauntlet/g55-opaque-nested-inference.jqd
  (ok(inference-posterior-v1(cons(mk-pair(<opaque box>, 0.3), cons(mk-pair(<opaque box>, 0.7), nil)), inference-metadata-v1(inference-exact-enumeration-v1, true, none, 8, 2))), ok(inference-posterior-v1(cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), cons(mk-pair(<opaque box>, 0.05), nil)))))))))))))))))))), inference-metadata-v1(inference-likelihood-weighting-v1, false, some(42), 20, 20))), ok(inference-posterior-v1(cons(mk-pair((<opaque box>, 2), 0.16666666666666666), cons(mk-pair((<opaque box>, 2), 0.16666666666666666), cons(mk-pair((<opaque box>, 2), 0.16666666666666666), cons(mk-pair((<opaque box>, 2), 0.16666666666666666), cons(mk-pair((<opaque box>, 2), 0.16666666666666666), cons(mk-pair((<opaque box>, 2), 0.16666666666666666), nil)))))), inference-metadata-v1(inference-likelihood-weighting-v1, false, some(9), 6, 6))), 0.7)
