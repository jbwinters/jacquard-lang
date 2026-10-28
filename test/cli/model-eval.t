Model documents (MODEL.1): `jacquard model eval DOC` evaluates every result of a
jacquard-model-v1 document and serves a result from the cache while its
dependency key is unchanged (docs/designs/model-dependencies.md).

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cat > m.jac <<'JAC'
  > helper(x) = add(x, 2)
  > other(x) = add(x, 1)
  > scale(n, k) = helper(add(n, k))
  > shift(n) = other(n)
  > echo(t) = t
  > greet(t) = print(t)
  > coin(p) = sample(Bernoulli(p))
  > spin(n) = spin(add(n, 1))
  > boom(n) = div(n, 0)
  > adder(n) = fn (x) -> add(x, n)
  > JAC
  $ printf 'hi\n' > note.txt
  $ cat > doc.model <<'DOC'
  > jacquard-model format=1
  > source m.jac
  > assumption base = 3
  > assumption chance = 0.3
  > input note text note.txt
  > result scaled entry scale args base,4 driver run fuel=10000
  > result shifted entry shift args base driver run fuel=10000
  > result echoed entry echo args note driver run fuel=10000
  > result flip entry coin args chance driver enumerate max-branches=10 fuel=100000
  > result flip-lw entry coin args chance driver lw seed=7 samples=50 fuel=1000000
  > result broken entry boom args 1 driver run fuel=1000
  > DOC

The first evaluation runs every result and stores each fully replayable
outcome; the second serves all of them.

  $ jacquard model eval doc.model
  scaled: fresh
    value 9
  shifted: fresh
    value 4
  echoed: fresh
    value "hi\n"
  flip: fresh
    posterior complete, 2 paths explored
      0.700000  false#c665b4997cada5268e43d722a9da3883b9eddd5e10ef5b1d39ee5c0034390e8c
      0.300000  true#bf5c9d86f11ef2591a2f1b7b9dcbc26342dcb093fce099341ce56e14b75482fb
  flip-lw: fresh
    posterior sampled, 50 runs
      0.600000  false#c665b4997cada5268e43d722a9da3883b9eddd5e10ef5b1d39ee5c0034390e8c
      0.400000  true#bf5c9d86f11ef2591a2f1b7b9dcbc26342dcb093fce099341ce56e14b75482fb
  broken: fresh
    failure arithmetic
  [2]
  $ jacquard model eval doc.model > second.out; echo "exit=$?"; grep ':' second.out
  exit=2
  scaled: cached
  shifted: cached
  echoed: cached
  flip: cached
  flip-lw: cached
  broken: cached

The cache is owner-only, and a fresh evaluation into another cache writes the
same bytes.

  $ stat -c %a .jacquard/model-cache .jacquard/model-cache/outcomes
  700
  700
  $ stat -c %a .jacquard/model-cache/outcomes/* | sort -u
  600
  $ jacquard model eval doc.model --cache other > /dev/null; echo "exit=$?"
  exit=2
  $ for f in other/outcomes/*; do cmp "$f" ".jacquard/model-cache/outcomes/${f##*/}" || echo differs; done; ls other/outcomes | wc -l
  6

Each edit recomputes exactly the results that depend on it.

  $ sed -i 's/base = 3/base = 5/' doc.model
  $ jacquard model eval doc.model > base.out; grep ':' base.out
  scaled: fresh
  shifted: fresh
  echoed: cached
  flip: cached
  flip-lw: cached
  broken: cached
  $ printf 'bye\n' > note.txt
  $ jacquard model eval doc.model > input.out; grep ':' input.out
  scaled: cached
  shifted: cached
  echoed: fresh
  flip: cached
  flip-lw: cached
  broken: cached
  $ sed -i 's/seed=7/seed=8/' doc.model
  $ jacquard model eval doc.model > seed.out; grep ':' seed.out
  scaled: cached
  shifted: cached
  echoed: cached
  flip: cached
  flip-lw: fresh
  broken: cached
  $ sed -i 's/add(x, 1)/add(x, 10)/' m.jac
  $ jacquard model eval doc.model > program.out; grep -A1 ':' program.out
  scaled: cached
    value 11
  shifted: fresh
    value 15
  echoed: cached
    value "bye\n"
  flip: cached
    posterior complete, 2 paths explored
  --
  flip-lw: cached
    posterior sampled, 50 runs
  --
  broken: cached
    failure arithmetic

Changing only the entry's call labels, or the policy, also recomputes exactly
what depends on it.

  $ sed -i 's/^scale(n, k) =/scale(n, by: k) =/' m.jac
  $ jacquard model eval doc.model > labels.out; grep ':' labels.out
  scaled: fresh
  shifted: cached
  echoed: cached
  flip: cached
  flip-lw: cached
  broken: cached
  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=none\nunlisted=ignore\noperations=0\n' > small.policy
  $ sed -i 's/^source m.jac$/source m.jac\npolicy small.policy/' doc.model
  $ jacquard model eval doc.model > policy.out; grep ':' policy.out
  scaled: fresh
  shifted: fresh
  echoed: fresh
  flip: fresh
  flip-lw: fresh
  broken: fresh
  $ sed -i '/^policy small.policy$/d' doc.model

A corrupt cache file is ignored with a warning and replaced.

  $ for f in .jacquard/model-cache/outcomes/*; do echo garbage > "$f"; done
  $ jacquard model eval doc.model > corrupt.out 2> corrupt.err; grep -c W1800 corrupt.err; grep -c fresh corrupt.out
  6
  6
  $ jacquard model eval doc.model > again.out; grep -c cached again.out
  6

Results that cannot be replayed are evaluated and shown but never stored: a
run that exhausts its fuel, and a value with an opaque part. `--no-cache`
neither reads nor writes.

  $ cat > hermetic.model <<'DOC'
  > jacquard-model format=1
  > source m.jac
  > result looping entry spin args 0 driver run fuel=500
  > result closure entry adder args 1 driver run fuel=1000
  > result plain entry scale args 1,2 driver run fuel=1000
  > DOC
  $ jacquard model eval hermetic.model --cache h
  looping: uncacheable (fuel)
    incomplete: the fuel budget ran out
  closure: uncacheable (closure)
    value <closure>
  plain: fresh
    value 5
  [2]
  $ ls h/outcomes | wc -l
  1
  $ jacquard model eval hermetic.model --no-cache > nocache.out; grep plain nocache.out
  plain: uncacheable (no-cache)

An entry that needs a root grant is refused before it runs; with `--allow`
the grants are installed and no result of the document is cached.

  $ cat > world.model <<'DOC'
  > jacquard-model format=1
  > source m.jac
  > input note text note.txt
  > result greeted entry greet args note driver run fuel=10000
  > result plain entry scale args 1,2 driver run fuel=1000
  > DOC
  $ jacquard model eval world.model --cache w
  greeted: refused
  error[E1806]: A model result needs a root grant that was not given.
    Cause: line 4: result greeted requires console, which only a root grant provides
    Next step: Evaluate with --allow for those effects; such results are never cached.
  plain: fresh
    value 5
  [3]
  $ jacquard model eval world.model --cache w2 --allow console
  bye
  greeted: uncacheable (root-grants)
    value ()
  plain: uncacheable (root-grants)
    value 5
  $ test -e w2/outcomes || echo "nothing stored"
  nothing stored

The JSON form carries each result's key, status and typed outcome.

  $ jacquard model eval hermetic.model --cache h --json > out.json; echo "exit=$?"
  exit=2
  $ grep -o '"format":"[a-z0-9-]*"' out.json; grep -o '"status":"[a-z]*"' out.json; grep -o '"tag":"[a-z]*"' out.json
  "format":"jacquard-model-eval-v1"
  "status":"uncacheable"
  "status":"uncacheable"
  "status":"cached"
  "tag":"incomplete"
  "tag":"value"
  "tag":"value"

Document errors are reported before anything runs.

  $ printf 'jacquard-model format=1\nsource m.jac\nresult r entry scale args base driver run fuel=10\n' > bad.model
  $ jacquard model eval bad.model
  error[E1802]: A result argument does not name exactly one assumption, input, or exported term.
    Cause: line 3: result r: "base" is not an assumption, an input, or an exported term
    Next step: Declare the name, rename the clashing declaration, or export the term from the source.
  [1]

With `--json`, output the program prints goes to stderr, so stdout holds only
the JSON object.

  $ jacquard model eval world.model --cache w3 --allow console --json > allow.json 2> allow.err; echo "exit=$?"
  exit=0
  $ cat allow.err
  bye
  $ head -c 34 allow.json; echo
  {"format":"jacquard-model-eval-v1"

A file that is not a regular file is refused without blocking.

  $ mkfifo pipe.txt
  $ sed 's/note.txt/pipe.txt/' world.model > fifo.model
  $ timeout 10 jacquard model eval fifo.model
  error[E1804]: A file the model document names cannot be used.
    Cause: input note (line 3) ./pipe.txt cannot be read: not a regular file
    Next step: Check that the file exists, is a regular file within the size limit, and is valid.
  [1]

`jacquard model explain DOC [RESULT]` says whether each result is current,
names every key component that changed since its last evaluation, and what
changed at its last recomputation, from the cache's history and snapshots.

  $ mkdir ex && cd ex
  $ cat > m.jac <<'JAC'
  > helper(x) = add(x, 2)
  > scale(n, k) = helper(add(n, k))
  > echo(t) = t
  > JAC
  $ printf 'hi\n' > note.txt
  $ cat > doc.model <<'DOC'
  > jacquard-model format=1
  > source m.jac
  > assumption base = 3
  > input note text note.txt
  > result scaled entry scale args base,4 driver run fuel=10000
  > result echoed entry echo args note driver run fuel=10000
  > DOC
  $ jacquard model explain doc.model
  scaled: never evaluated
  echoed: never evaluated
  $ jacquard model eval doc.model > /dev/null
  $ jacquard model explain doc.model > a.out; sed -E 's/[0-9]{4}-[0-9-]+T[0-9:]+Z/TIME/' a.out
  scaled: current (evaluated TIME)
  echoed: current (evaluated TIME)
  $ sed -i 's/base = 3/base = 5/' doc.model
  $ printf 'bye!\n' > note.txt
  $ jacquard model explain doc.model > b.out; sed -E 's/[0-9]{4}-[0-9-]+T[0-9:]+Z/TIME/' b.out
  scaled: stale (last evaluated TIME)
    assumption base: 3 -> 5
  echoed: stale (last evaluated TIME)
    input note: 3 bytes -> 5 bytes
  $ jacquard model eval doc.model > /dev/null
  $ sed -i 's/add(x, 2)/add(x, 9)/' m.jac
  $ sed -i 's/args base,4 driver run fuel=10000/args base,4 driver run fuel=20000/' doc.model
  $ jacquard model explain doc.model scaled > c.out; sed -E 's/[0-9]{4}-[0-9-]+T[0-9:]+Z/TIME/' c.out
  scaled: stale (last evaluated TIME)
    entry scale changed
    fuel: 10000 -> 20000
    last change (TIME):
      assumption base: 3 -> 5

A pruned snapshot is shown as unavailable, never guessed; an unreadable
history is reported as such.

  $ jacquard model eval doc.model > /dev/null
  $ rm .jacquard/model-cache/snapshots/*
  $ sed -i 's/base = 5/base = 7/' doc.model
  $ jacquard model explain doc.model scaled > d.out; sed -E 's/[0-9]{4}-[0-9-]+T[0-9:]+Z/TIME/' d.out
  scaled: stale (last evaluated TIME)
    assumption base: (unavailable) -> 7
    last change (TIME):
      entry scale changed
      fuel: 10000 -> 20000
  $ for h in .jacquard/model-cache/history/*/echoed; do echo junk >> "$h"; done
  $ jacquard model explain doc.model echoed
  echoed: history unavailable (bad frame)
  $ jacquard model explain doc.model nope
  error[E1802]: The model document has no such result.
    Cause: doc.model declares no result "nope"
    Next step: Name a result the document declares.
  [1]
  $ jacquard model explain doc.model --json > e.json; grep -o '"freshness":"[a-z-]*"' e.json
  "freshness":"stale"
  "freshness":"history-unavailable"
  $ stat -c %a .jacquard/model-cache/history/*/scaled
  600
