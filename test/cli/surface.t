SS.16: `.jac` is a first-class CLI carrier while `.jqd` keeps its bootstrap contract.

  $ export JACQUARD_PRELUDE=../../prelude

All five source commands run through the built/package `jac` alias and extension detection. The
public pure demo and the bare-top-level-expression demo both execute directly.

  $ jac run ../../demos/basics/surface-fact.jac
  120
  $ jac run ../../demos/basics/surface-expression.jac
  42
  $ jac check ../../demos/basics/surface-fact.jac
  ok
  $ jac hash ../../demos/basics/surface-expression.jac | sed 's/[0-9a-f]\{64\}/HASH/'
  0 HASH

D40 executes every bare top-level expression in document order while declarations before, between,
and after expressions remain available to the following items. Stdout and exit are exact.

  $ cat > ordered-top-level.jac <<'EOF'
  > first = 40
  > first
  > second = add(first, 1)
  > second
  > third = add(second, 1)
  > third
  > EOF
  $ jac run ordered-top-level.jac > ordered.out 2> ordered.err; status=$?; cat ordered.out; cat ordered.err; echo "exit:$status"
  40
  41
  42
  exit:0

D36 labeled fields retain syntax and printing, but accessor definitions are not generated at this
gate. The exact current evidence is E0301 and exit 1; the durable acceptance target is in FOLLOWUPS.

  $ cat > no-generated-accessor.jac <<'EOF'
  > type Pair = | Pair(left: Int, right: Int)
  > pair.left(Pair(1, 2))
  > EOF
  $ jac run no-generated-accessor.jac > accessor.out 2>&1; status=$?; cat accessor.out; echo "exit:$status"
  no-generated-accessor.jac:2:1-10: error[E0301]: unknown name `pair.left`
  exit:1

The surface formatter preserves trivia, applies B1/B5, and is idempotent.

  $ cat > format.jac <<'EOF'
  > --| outcomes
  > type DeploymentOutcome=|CompletelyClear|UnexpectedlyChoppy|TemporarilyUnavailable|PermanentlyBlacklisted
  > choose(x)=match x{|True->{let y=int.add(x,1);int.add(y,2)}|False->very-long-function-name("first-long-argument","second-long-argument","third-long-argument","fourth-long-argument")}
  > EOF
  $ jac fmt format.jac > once.jac
  $ jac fmt once.jac > twice.jac
  $ cmp once.jac twice.jac && echo idempotent
  idempotent
  $ grep -c '^--| outcomes$' once.jac
  1
  $ grep -A2 '^type DeploymentOutcome' once.jac
  type DeploymentOutcome =
    | CompletelyClear
    | UnexpectedlyChoppy
  $ grep -A3 '| True' once.jac
      | True -> {
        let y = int.add(x, 1)
        int.add(y, 2)
      }
  $ grep '| False' once.jac
      | False ->

B3 is lint-only: the formatter leaves the first over-boundary scrutinee in place and recommends a
manual hoist. The warning is emitted on stderr and formatting remains successful.

  $ cat > large.jac <<'EOF'
  > match add(
  >   1,
  >   2,
  >   3
  > ) { | _ -> 0 }
  > EOF
  $ jac fmt large.jac > large-formatted.jac 2> large.err
  $ grep 'warning\[W1203\]' large.err
  large.jac:1:7-5:2: warning[W1203]: this match scrutinee spans 5 lines; scrutinees longer than 4 lines are difficult to review
  $ head -1 large-formatted.jac
  match add(1, 2, 3) {

DX.3 keeps realistic nested quotes, matches, handlers, conditionals, and blocks stable under
formatting and canonical identity. Explicit operation namespace intent survives the formatter.

  $ mkdir -p dx3
  $ for source in ../../corpus/surface/dx3/valid/*.jac; do name=$(basename "$source"); jac fmt "$source" > "dx3/$name"; jac fmt "dx3/$name" > "dx3/$name.twice"; cmp "dx3/$name" "dx3/$name.twice"; jac hash "$source" > "dx3/$name.before-hash"; jac hash "dx3/$name" > "dx3/$name.after-hash"; cmp "dx3/$name.before-hash" "dx3/$name.after-hash"; done
  $ find dx3 -name '*.jac' | wc -l
  3
  $ grep -F '`op:net.request`' dx3/preflight-policy.jac
            if int.gt?(telemetry, unquote(threshold-code)) then quote { `op:net.request`("release") }

Malformed nested source remains invalid. The formatter emits no recovered source, while `check`
uses recovery analysis to report one primary syntax error, check a later independent error, and
retain the later valid declaration before exiting nonzero.

  $ cp ../../corpus/surface/dx3/malformed/missing-quote.jac dx3/missing-quote.jac
  $ jac fmt dx3/missing-quote.jac > dx3/malformed.out 2> dx3/malformed.err; status=$?; wc -c < dx3/malformed.out; cat dx3/malformed.err; echo "exit:$status"
  0
  dx3/missing-quote.jac:6:1-10: error[E1221]: unclosed `quote`: expected `}` before ident(later-bad)
    hint: the `quote` expression opened at dx3/missing-quote.jac:1:10-15
  exit:1
  $ jac check dx3/missing-quote.jac --print-sigs > dx3/check.out 2>&1; status=$?; cat dx3/check.out; echo "exit:$status"
  dx3/missing-quote.jac:6:1-10: error[E1221]: unclosed `quote`: expected `}` before ident(later-bad)
    hint: the `quote` expression opened at dx3/missing-quote.jac:1:10-15
  dx3/missing-quote.jac:6:16-17: error[E0801]: if condition: expected int, got bool (type mismatch)
    hint: the expected side comes from the surrounding context; make both sides agree
  broken : forall a. a
  later-good : Int
  exit:1
  $ for source in ../../corpus/surface/dx3/malformed/*.jac; do jac fmt "$source" >/dev/null 2>/dev/null; fmt_status=$?; jac check "$source" >/dev/null 2>/dev/null; check_status=$?; test "$fmt_status" -eq 1 && test "$check_status" -eq 1 || exit 1; done; echo all-malformed-refused
  all-malformed-refused

File diff parses, lowers, and resolves each side before using semantic identity. Trivia-only edits
are quiet; semantic edits localize in surface notation. Explicit syntax handles extensionless files.

  $ cat > old.jac <<'EOF'
  > answer = 1
  > EOF
  $ cat > same.jac <<'EOF'
  > -- same declaration with trivia
  > answer=1
  > EOF
  $ cat > changed.jac <<'EOF'
  > answer = 2
  > EOF
  $ jac diff old.jac same.jac
  no semantic changes
  $ jac diff old.jac changed.jac | grep -A2 'at answer'
    at answer/defterm[0]/group[0]/binding[2]/lit[0]:
      - 1
      + 2
  $ printf 'result = 1\n' > renamed.jac
  $ jac diff old.jac renamed.jac
  renamed  answer -> result
  $ cp same.jac same-source
  $ jac diff old.jac same-source --syntax surface
  no semantic changes

Source operands own only their declarations even though the prelude remains available while
resolving them. A source declaration that collides with the prelude `add` binding is therefore an
addition or removal, not a change against the builtin marker; source-local dependents remain useful.

  $ : > no-declarations.jac
  $ cat > add-old.jac <<'EOF'
  > add(x, y) = x
  > EOF
  $ cat > add-new.jac <<'EOF'
  > add(x, y) = y
  > EOF
  $ jac diff no-declarations.jac add-old.jac
  added    add
  $ jac diff add-old.jac no-declarations.jac
  removed  add
  $ cat > add-dependent-old.jac <<'EOF'
  > add(x, y) = x
  > uses-add(x) = add(x, 1)
  > EOF
  $ cat > add-dependent-new.jac <<'EOF'
  > add(x, y) = y
  > uses-add(x) = add(x, 1)
  > EOF
  $ jac diff add-dependent-old.jac add-dependent-new.jac | grep -E '^(changed|  dependents:)'
  changed  add
    dependents: uses-add
  changed  uses-add
  $ : > no-declarations.jqd
  $ printf '(defterm ((binding add () (lam ((pvar x) (pvar y)) (var x)))))\n' > add-collision.jqd
  $ jac diff no-declarations.jqd add-collision.jqd
  added    add

Malformed source and file/store operand mistakes produce diagnostics with exit 1, not exceptions.

  $ printf 'answer = @\n' > malformed.jac
  $ jac diff malformed.jac old.jac > malformed.out 2>&1; status=$?; grep -o 'error\[E1210\]' malformed.out | head -1; echo "exit:$status"
  error[E1210]
  exit:1
  $ mkdir one-store
  $ jac diff old.jac one-store > mixed.out 2>&1; status=$?; cat mixed.out; echo "exit:$status"
  error[E0609]: cannot compare a source file with a store directory; pass two files or two stores
  exit:1
  $ jac diff missing.jac old.jac > missing.out 2>&1; status=$?; cat missing.out; echo "exit:$status"
  error[E0606]: diff operand missing.jac does not exist
  exit:1

Store diff keeps its established bootstrap default and offers explicit surface rendering.

  $ printf '(defterm ((binding answer () (lit 1))))\n' > old.jqd
  $ printf '(defterm ((binding answer () (lit 2))))\n' > new.jqd
  $ jac store add old-store old.jqd
  ok
  $ jac store add new-store new.jqd
  ok
  $ jac diff old-store new-store --syntax surface | grep -A2 'at answer'
    at answer/defterm[0]/group[0]/binding[2]/lit[0]:
      - 1
      + 2

Bootstrap formatting and execution remain byte-for-byte on the old route.

  $ jac diff old.jqd new.jqd | grep -A2 'at answer'
    at answer/defterm[0]/group[0]/binding[2]/lit[0]:
      - 1
      + 2
  $ printf '(app (var add) (lit 20) (lit 22))\n' > unchanged.jqd
  $ jac fmt unchanged.jqd
  (app
    (var add)
    (lit 20)
    (lit 22))
  $ jac run unchanged.jqd
  42
