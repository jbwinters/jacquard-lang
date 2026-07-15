Native compilation (docs/native-plan.md, tasks 67-71): the effect-full
language — pure programs, tail-resumptive handlers, and capturing/multi-shot
handlers — compiles to standalone binaries whose output is byte-identical to
the interpreter. v1 requires clang (musttail).

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

Ten pure programs, interpreter vs native, byte-compared (stdout and exit):

  $ for f in lit-int app-add lit-real lit-text tuple-unit let-shadow match-bool fact even-odd prelude-map; do
  >   jacquard run ../../corpus/valid/$f.jqd > i.out 2>&1
  >   jacquard build ../../corpus/valid/$f.jqd -o prog > /dev/null 2>&1
  >   ./prog > n.out 2>&1
  >   if diff -q i.out n.out > /dev/null; then echo "identical: $f"; else echo "DIVERGED: $f"; diff i.out n.out; fi
  > done
  identical: lit-int
  identical: app-add
  identical: lit-real
  identical: lit-text
  identical: tuple-unit
  identical: let-shadow
  identical: match-bool
  identical: fact
  identical: even-odd
  identical: prelude-map

The benchmark file (recursion, list traffic, a dictionary sort) too:

  $ jacquard run ../../bench/pure.jqd > i.out 2>&1
  $ jacquard build ../../bench/pure.jqd -o bench-prog
  native: compiled 16 unit(s)
  $ ./bench-prog > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical

The unit cache is content-addressed: an unchanged program recompiles nothing.

  $ jacquard build ../../bench/pure.jqd -o bench-prog2
  native: compiled 0 unit(s)

Monomorphization (task 69): a sort at int.ord erases its dictionary — the
specialized unit calls the comparator intrinsic directly and contains no
generic apply at all — and the spec cache is content-addressed like every
other unit (second build recompiles nothing).

  $ cat > sortprog.jqd <<'EOF_JQD'
  > (app (var list.length) (app (var list.sort) (app (var list.reverse) (app (var list.range) (lit 0) (lit 100))) (var int.ord)))
  > EOF_JQD
  $ jacquard build sortprog.jqd -o sortprog > /dev/null
  $ ./sortprog
  100
  $ grep -l 'jq_i_int_compare' .jacquard-native/v1-h*/unit_*.c | wc -l | tr -d ' '
  1
  $ grep -c 'jq_apply' $(grep -l 'jq_i_int_compare' .jacquard-native/v1-h*/unit_*.c)
  0
  [1]
  $ jacquard build sortprog.jqd -o sortprog2
  native: compiled 0 unit(s)
  $ JACQUARD_SPEC=off jacquard build sortprog.jqd -o sortprog-ns > /dev/null
  $ ./sortprog-ns
  100

Since task 86 the spec key also covers capture-free lambda literals: a
fold at a known lambda erases the apply AND leaves the frame tier — the
clone calls the lambda's code directly, so no generic apply and no
resume machinery remain in its unit, and Perceus owns its counts again.

  $ cat > foldprog.jqd <<'EOF_JQD'
  > (app (var list.fold) (app (var list.range) (lit 0) (lit 100)) (lit 0) (lam ((pvar a) (pvar x)) (app (var add) (var a) (var x))))
  > EOF_JQD
  $ jacquard build foldprog.jqd -o foldprog > /dev/null
  $ ./foldprog
  4950
  $ grep -l 'fold@spec' .jacquard-native/v1-h*/unit_*.c | wc -l | tr -d ' '
  2
  $ cat $(grep -l 'fold@spec' .jacquard-native/v1-h*/unit_*.c) | grep -c 'jq_apply'
  0
  [1]
  $ cat $(grep -l 'fold@spec' .jacquard-native/v1-h*/unit_*.c) | grep -c '_re('
  0
  [1]

(Two clones: bench/pure.jqd's earlier build in this test specializes its
own sum-fold lambda; both are apply-free and frame-free.)
  $ JACQUARD_SPEC=off jacquard build foldprog.jqd -o foldprog-ns > /dev/null
  $ ./foldprog-ns
  4950

Ineligible REACHABLE constructs are errors naming the construct and its
home, never silent miscompiles — since task 73 that means eval alone
(E1102 policy: dynamically loaded code runs at the interpreter tier;
quotes and the structural code ops compile). (Unreachable declarations
are fine: eligibility walks the dependency DAG from the top-level
expressions, not the whole file.)

  $ cat > handler-ret.jqd <<'EOF_JQD'
  > (handle (lit 1) (ret (pvar x) (var x)))
  > EOF_JQD
  $ jacquard build handler-ret.jqd -o ret-only > /dev/null
  $ ./ret-only
  1
  $ cat > multishot.jqd <<'EOF_JQD'
  > (handle (app (var get))
  >   (ret (pvar x) (var x))
  >   (opclause get () k
  >     (let nonrec (pvar a) (app (var k) (lit 1))
  >       (app (var k) (lit 2)))))
  > EOF_JQD
  $ jacquard run multishot.jqd
  2
  $ jacquard build multishot.jqd -o multishot > /dev/null
  $ ./multishot
  2
  $ jacquard build ../../corpus/valid/eval-gated.jqd -o nope
  error[E1102]: top-level expression 0 uses eval, which requires the interpreter tier
  [1]

Quotes compile since task 73 — Value.show of a code value is the ported
inline printer, byte-for-byte:

  $ cat > quoted.jqd <<'EOF_JQD'
  > (quote (lit 1))
  > EOF_JQD
  $ jacquard run quoted.jqd > i.out 2>&1
  $ jacquard build quoted.jqd -o quoted > /dev/null
  $ ./quoted > n.out 2>&1
  $ cat n.out
  (quote (lit 1))
  $ diff i.out n.out && echo identical
  identical

Effects (task 70): a perform dispatches to the nearest handler; a handler
discharging its effect in-language needs no grant:

  $ cat > get42.jqd <<'EOF_JQD'
  > (handle (app (var add) (app (var get)) (lit 1))
  >   (ret (pvar x) (var x))
  >   (opclause get () k (app (var k) (lit 41))))
  > EOF_JQD
  $ jacquard run get42.jqd > i.out 2>&1
  $ jacquard build get42.jqd -o get42 > /dev/null
  $ ./get42 > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical

Root grants are the --allow natives, parsed by the generated main. Console
hello, both legs: granted, and refused with E0814's exact rendering at
exit 3:

  $ cat > hello.jqd <<'EOF_JQD'
  > (app (var println) (lit "hello, native"))
  > EOF_JQD
  $ jacquard build hello.jqd -o hello > /dev/null
  $ jacquard run hello.jqd --allow console > i.out 2>&1
  $ ./hello --allow console > n.out 2>&1
  $ cat n.out
  hello, native
  ()
  $ diff i.out n.out && echo identical
  identical
  $ jacquard run hello.jqd > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./hello > n.out 2>&1; echo "exit $?"
  exit 3
  $ diff i.out n.out && echo identical
  identical

Grant names never identify effects. A user declaration named `console` stays
unregistered in both engines, even with `--allow console`; the generated binary
keeps its manifest and grant slots keyed by the resolved declaration hash:

  $ cat > spoof-console.jqd <<'EOF_JQD'
  > (defeffect console () (op print once ((tref text)) (ttuple)))
  > (app (var print) (lit "spoof"))
  > EOF_JQD
  $ jacquard build spoof-console.jqd -o spoof-console > /dev/null
  $ jacquard run spoof-console.jqd > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./spoof-console > n.out 2>&1; echo "exit $?"
  exit 3
  $ diff i.out n.out && echo identical
  identical
  $ cat n.out
  error[E0814]: this program requires unpackaged:5c34b2aa7fe3/console [unrated user effect #5c34b2aa7fe357ee14e3be78853839546a63f40fe47b597176620e00d8ec58f0], which is not granted (performed via `print`)
    hint: handle the effect in the program (unregistered user effects have no built-in --allow grant)
  $ jacquard run spoof-console.jqd --allow console > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./spoof-console --allow console > n.out 2>&1; echo "exit $?"
  exit 3
  $ diff i.out n.out && echo identical
  identical
  $ cat n.out
  error[E0814]: this program requires unpackaged:5c34b2aa7fe3/console [unrated user effect #5c34b2aa7fe357ee14e3be78853839546a63f40fe47b597176620e00d8ec58f0], which is not granted (performed via `print`)
    hint: handle the effect in the program (unregistered user effects have no built-in --allow grant)

The official and user-defined `console` identities can coexist in one row.
Without a grant both are reported distinctly; granting the blessed identity
removes only that requirement and leaves the user effect refused:

  $ cat > two-consoles.jqd <<'EOF_JQD'
  > (defeffect console () (op print once ((tref text)) (ttuple)))
  > (let nonrec (pwild) (app (var println) (lit "official"))
  >   (app (var print) (lit "spoof")))
  > EOF_JQD
  $ jacquard build two-consoles.jqd -o two-consoles > /dev/null
  $ jacquard run two-consoles.jqd > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./two-consoles > n.out 2>&1; echo "exit $?"
  exit 3
  $ diff i.out n.out && echo identical
  identical
  $ cat n.out
  error[E0814]: this program requires unpackaged:5c34b2aa7fe3/console [unrated user effect #5c34b2aa7fe357ee14e3be78853839546a63f40fe47b597176620e00d8ec58f0], which is not granted (performed via `print`)
    hint: handle the effect in the program (unregistered user effects have no built-in --allow grant)
  error[E0814]: this program requires console [world/low] — talk to the process terminal, which is not granted (performed via `println`)
    hint: grant it with --allow console, or handle the effect in the program
  $ jacquard run two-consoles.jqd --allow console > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./two-consoles --allow console > n.out 2>&1; echo "exit $?"
  exit 3
  $ diff i.out n.out && echo identical
  identical
  $ cat n.out
  error[E0814]: this program requires unpackaged:5c34b2aa7fe3/console [unrated user effect #5c34b2aa7fe357ee14e3be78853839546a63f40fe47b597176620e00d8ec58f0], which is not granted (performed via `print`)
    hint: handle the effect in the program (unregistered user effects have no built-in --allow grant)

A later expression's refusal happens at ITS turn: the first expression's
value has already printed and flushed on both engines, so it precedes the
error even in a merged capture:

  $ cat > interleave.jqd <<'EOF_JQD'
  > (lit 1)
  > (app (var println) (lit "reached?"))
  > EOF_JQD
  $ jacquard build interleave.jqd -o interleave > /dev/null
  $ jacquard run interleave.jqd > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./interleave > n.out 2>&1; echo "exit $?"
  exit 3
  $ cat n.out
  1
  error[E0814]: this program requires console [world/low] — talk to the process terminal, which is not granted (performed via `println`)
    hint: grant it with --allow console, or handle the effect in the program
  $ diff i.out n.out && echo identical
  identical

demos/tooling/word-count.jqd — the task-70 definition of done — granted and
refused, byte-identical both ways:

  $ echo "the quick brown fox the lazy dog the fox" | jacquard run ../../demos/tooling/word-count.jqd --allow console > i.out 2>&1
  $ jacquard build ../../demos/tooling/word-count.jqd -o wc-prog > /dev/null
  $ echo "the quick brown fox the lazy dog the fox" | ./wc-prog --allow console > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical
  $ jacquard run ../../demos/tooling/word-count.jqd > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./wc-prog > n.out 2>&1; echo "exit $?"
  exit 3
  $ diff i.out n.out && echo identical
  identical

An expression needing TWO ungranted effects reports both before the one
exit, like the interpreter's manifest_errors batch; and the equals
spelling of --allow works like cmdliner's:

  $ cat > two-eff.jqd <<'EOF_JQD'
  > (let nonrec (pwild) (app (var println) (lit "x")) (app (var now)))
  > EOF_JQD
  $ jacquard build two-eff.jqd -o two-eff > /dev/null
  $ jacquard run two-eff.jqd > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./two-eff > n.out 2>&1; echo "exit $?"
  exit 3
  $ cat n.out
  error[E0814]: this program requires console [world/low] — talk to the process terminal, which is not granted (performed via `println`)
    hint: grant it with --allow console, or handle the effect in the program
  error[E0814]: this program requires clock [world/low] — observe wall-clock milliseconds or wait, which is not granted (performed via `now`)
    hint: grant it with --allow clock, or handle the effect in the program
  $ diff i.out n.out && echo identical
  identical
  $ jacquard run hello.jqd --allow=console > i.out 2>&1
  $ ./hello --allow=console > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical

A clock handler discharging `now` in-language: deterministic, no grant
needed (the row is empty), byte-identical:

  $ cat > clock-fixed.jqd <<'EOF_JQD'
  > (handle (app (var sub) (app (var now)) (app (var now)))
  >   (ret (pvar x) (var x))
  >   (opclause now () k (app (var k) (lit 1000))))
  > EOF_JQD
  $ jacquard run clock-fixed.jqd > i.out 2>&1
  $ jacquard build clock-fixed.jqd -o clock-fixed > /dev/null
  $ ./clock-fixed > n.out 2>&1
  $ cat n.out
  0
  $ diff i.out n.out && echo identical
  identical

The clock grant natives (sleep 0 is the deterministic one):

  $ cat > sleep0.jqd <<'EOF_JQD'
  > (app (var sleep) (lit 0))
  > EOF_JQD
  $ jacquard build sleep0.jqd -o sleep0 > /dev/null
  $ jacquard run sleep0.jqd --allow clock > i.out 2>&1
  $ ./sleep0 --allow clock > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical
  $ ./sleep0 > n.out 2>&1; echo "exit $?"
  exit 3

The fs grant natives: a write/read round trip and a sorted list-dir under
a scratch dir, granted and refused, plus the io-error rendering (exit 2)
for a missing file:

  $ cat > fsdemo.jqd <<'EOF_JQD'
  > (let nonrec (pwild) (app (var write) (lit "fsdir/a.txt") (lit "alpha"))
  >   (let nonrec (pwild) (app (var write) (lit "fsdir/b.txt") (lit "beta"))
  >     (tuple (app (var read) (lit "fsdir/a.txt")) (app (var list-dir) (lit "fsdir")))))
  > EOF_JQD
  $ jacquard build fsdemo.jqd -o fsdemo > /dev/null
  $ mkdir fsdir && jacquard run fsdemo.jqd --allow fs > i.out 2>&1
  $ rm -r fsdir && mkdir fsdir && ./fsdemo --allow fs > n.out 2>&1
  $ cat n.out
  ("alpha", cons("a.txt", cons("b.txt", nil)))
  $ diff i.out n.out && echo identical
  identical
  $ jacquard run fsdemo.jqd > i.out 2>&1; echo "exit $?"
  exit 3
  $ ./fsdemo > n.out 2>&1; echo "exit $?"
  exit 3
  $ diff i.out n.out && echo identical
  identical
  $ cat > fsmiss.jqd <<'EOF_JQD'
  > (app (var read) (lit "no-such-file.txt"))
  > EOF_JQD
  $ jacquard build fsmiss.jqd -o fsmiss > /dev/null
  $ jacquard run fsmiss.jqd --allow fs > i.out 2>&1; echo "exit $?"
  exit 2
  $ ./fsmiss --allow fs > n.out 2>&1; echo "exit $?"
  exit 2
  $ cat n.out
  io error: no-such-file.txt: No such file or directory
  $ diff i.out n.out && echo identical
  identical

An unimplemented grant is an up-front error, not a silent no-op:

  $ ./fsmiss --allow net
  error[E1103]: native binaries implement only the console, clock, fs, dist, and infer grants so far (task 72); cannot grant `net`
  [1]
