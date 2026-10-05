The abstract-types demonstrations (docs/designs/abstract-types.md §4): three
library projects whose types are opaque (a probability in [0, 1], a non-empty
list, a validated signup request), each with its Warp suite, and one client
application that depends on all three. The client prints its recorded
transcript under the interpreter and natively, and it cannot build or take
apart a sealed value itself.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ export TMPDIR=$PWD/.scratch/tmp
  $ mkdir -p "$TMPDIR" && cp -RL ../../demos/abstract-types . && chmod -R u+w abstract-types
  $ A=$PWD/abstract-types

Each library's suite passes, NaN and out-of-range probabilities included:

  $ for lib in prob nel req; do
  >   jac project test --project "$A/$lib" --seed 42 --no-cache 2>&1 | tail -1
  > done
  6 passed, 0 failed, 0 skipped, 0 refused
  4 passed, 0 failed, 0 skipped, 0 refused
  6 passed, 0 failed, 0 skipped, 0 refused

The client needs only Console, and both engines print the recorded
transcript, in which an opaque value displays as its type alone:

  $ jac project check --project "$A/client" --strict-grants > /dev/null && echo grants ok
  grants ok
  $ jac project run --project "$A/client" demo --allow console > demo.out 2>&1; echo $?
  0
  $ jac project build --project "$A/client" demo -o client-native > /dev/null 2>&1; echo $?
  0
  $ ./client-native --allow console > demo.native 2>&1; echo $?
  0
  $ cmp demo.out "$A/client/EXAMPLE.txt" && cmp demo.native "$A/client/EXAMPLE.txt" && echo identical
  identical
  $ cat demo.out
  ABSTRACT TYPES: values a client holds were checked by their library
  P = 0.250; not P = 0.750
  P = 1.000; not P = 0.000
  refused: a probability lies in [0, 1]
  refused: a probability lies in [0, 1]
  both halves: 0.250
  first = 3; length after doubling = 3
  refused: the list is empty
  welcome Ada <ada@example.org>
  refused: the name is blank
  refused: the email has no @: grace
  refused: the age is outside 13..130: 9
  printed opaquely: <opaque prob-value>
  ()

The types are sealed: a library may not export the constructor of its opaque
type (E1736), so the redacted line above is the only view a client gets:

  $ cp "$A/prob/project.jqd" prob.bak
  $ sed -i 's/(type prob-value)/(type prob-value) (con prob-value)/' "$A/prob/project.jqd"
  $ jac project check --project "$A/prob" 2>&1 | grep -o 'error\[E1736\].*' | head -1
  error[E1736]: A manifest exports a sealed constructor.
  $ cp prob.bak "$A/prob/project.jqd"

The client's own construction or pattern match of a sealed value names a
constructor its library does not export (E1705), while the transparent
ReqInvalid reasons, which `req` does export, stay open to it:

  $ cp "$A/client/client.jac" client.bak
  $ echo 'client.forge() = ProbValue(2.0)' >> "$A/client/client.jac"
  $ jac project check --project "$A/client" 2>&1 | grep -o 'error\[E1705\].*' | head -1
  error[E1705]: A name is not visible in this project.
  $ cp client.bak "$A/client/client.jac"
  $ echo 'client.peek(r) = match r { | ReqValid(name, _, _) -> name }' >> "$A/client/client.jac"
  $ jac project check --project "$A/client" 2>&1 | grep -o 'error\[E1705\].*' | head -1
  error[E1705]: A name is not visible in this project.
  $ cp client.bak "$A/client/client.jac"
  $ echo 'client.why() = req.reason(BadEmail("x"))' >> "$A/client/client.jac"
  $ jac project check --project "$A/client" > /dev/null && echo transparent ok
  transparent ok
  $ cp client.bak "$A/client/client.jac"
