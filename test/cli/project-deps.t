Projects with dependencies (PKG.1, docs/designs/project-structure.md §5, §8).
Two libraries each keep a private `helper`; an application uses both.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir -p work/liba work/libb work/app && cd work && mkdir .git
  $ cat > liba/project.jqd <<'M'
  > (project-v1 (name "liba") (requires (core "0.2")) (namespace liba) (units "a.jac")
  >   (exports (term liba.shout) (type liba-box)))
  > M
  $ cat > liba/a.jac <<'S'
  > type LibaBox = | LibaBox(value: Int)
  > liba.helper(x, by: amount) = int.add(x, amount)
  > liba.shout(x) = LibaBox(liba.helper(x, by: 100))
  > S
  $ cat > libb/project.jqd <<'M'
  > (project-v1 (name "libb") (requires (core "0.2")) (namespace libb) (units "b.jac")
  >   (exports (term libb.twice)))
  > M
  $ cat > libb/b.jac <<'S'
  > libb.helper(x) = int.add(x, x)
  > libb.twice(x) = libb.helper(x)
  > S
  $ cat > app/project.jqd <<'M'
  > (project-v1 (name "app") (requires (core "0.2")) (namespace app) (units "lib.jac")
  >   (deps (dep (as a) (path "../liba")) (dep (as b) (path "../libb")))
  >   (entries (run demo (units "demo.jac"))))
  > M
  $ echo 'app.go(x) = liba.shout(libb.twice(x))' > app/lib.jac
  $ echo 'app.go(1)' > app/demo.jac
  $ cd app
  $ hashes() { sed -E 's/[0-9a-f]{64}/HASH/g'; }

An unpinned dependency is refused until `project pin` records its context
identity; `--dry-run` writes nothing:

  $ jacquard project check 2>&1 | grep -A1 'E1711' | head -2
  error[E1711]: A dependency is unpinned.
    Cause: dependency app -> a is unpinned; run jacquard project pin
  $ jacquard project pin --dry-run | hashes
  a: unpinned -> HASH
  b: unpinned -> HASH
  $ grep -c '(pin' project.jqd
  0
  [1]
  $ jacquard project pin | hashes
  a: unpinned -> HASH
  b: unpinned -> HASH
  $ grep -c '(pin' project.jqd
  1
  $ jacquard project check | tail -2
  library: 1 declarations checked
  entry demo (run): checked; requires nothing
  $ jacquard project run demo
  liba-box(102)

The pin commits to semantics only: the dependency's name and metadata, and the
order of the consumer's dependencies, change nothing:

  $ sed -i 's/(name "liba")/(name "renamed") (metadata (note "x"))/' ../liba/project.jqd
  $ jacquard project pin --dry-run | hashes
  a: HASH (unchanged)
  b: HASH (unchanged)

A provider's interface covers its export projection: the abstract type's
constructor is a hidden member, and the private helper is absent:

  $ jacquard project interface --project ../liba | hashes | grep -v -e '^(prelude' -e '^$'
  context HASH
  (interface-v1
    (hash-algorithm "HASH_V0"))
  (export
    type
    liba-box
    #HASH
    (owner #HASH)
    (arity 0))
  (export
    term
    liba.shout
    #HASH
    (owner #HASH)
    (signature "(#HASH) ->{} #HASH"))
  (hidden
    #HASH
    (owner #HASH))

Private names, private hashes, and both inside eval payloads are refused, as is
the constructor of an abstract exported type:

  $ echo 'liba.helper(1, by: 2)' > demo.jac && jacquard project run demo 2>&1 | grep -A1 'error' | head -2
  $TESTCASE_ROOT/work/app/demo.jac:1:1-12: error[E1705]: A name is not visible in this project.
    Cause: `liba.helper` is private to project `liba`
  $ echo 'libb.helper(1)' > demo.jac && jacquard project run demo 2>&1 | grep -o 'error\[E1705\]'
  error[E1705]
  $ H=$(jacquard hash ../liba/a.jac | grep ':liba.helper ' | cut -d' ' -f2)
  $ printf '#%s:term(1, 2)\n' "$H" > demo.jac && jacquard project run demo 2>&1 | grep -A1 'error' | hashes
  $TESTCASE_ROOT/work/app/demo.jac:1:1-77: error[E1709]: An explicit identity is not visible in this project.
    Cause: hash HASH is not visible in project `app`: it belongs to project `liba`, which does not export it to this project
  $ echo '`op:eval-code`(quote { liba.helper(1, 2) })' > demo.jac && jacquard project run demo --allow eval 2>&1 | grep -o 'E1705'
  E1705
  $ printf '`op:eval-code`(quote { #%s:term(1, 2) })\n' "$H" > demo.jac && jacquard project run demo --allow eval 2>&1 | grep -o 'E1709'
  E1709
  $ echo 'LibaBox(1)' > demo.jac && jacquard project run demo 2>&1 | grep -A1 'error'
  $TESTCASE_ROOT/work/app/demo.jac:1:1-8: error[E1705]: A name is not visible in this project.
    Cause: `liba-box` is private to project `liba`
  $ echo 'app.go(1)' > demo.jac

A private body edit changes the interface component (the exported term's
identity); a private label edit changes only the companions:

  $ cp ../liba/a.jac a.bak
  $ sed -i 's/by: 100/by: 200/' ../liba/a.jac
  $ jacquard project check 2>&1 | grep -A1 'E1710' | hashes
  error[E1710]: A dependency's pin does not match its context identity.
    Cause: dependency app -> a is pinned to HASH but its context identity is HASH (changed: interface; breaking   term liba.shout: identity HASH -> HASH)
  $ cp a.bak ../liba/a.jac && sed -i 's/by: amount/plus: amount/; s/by: 100/plus: 100/' ../liba/a.jac
  $ jacquard project check 2>&1 | grep -A1 'E1710' | hashes
  error[E1710]: A dependency's pin does not match its context identity.
    Cause: dependency app -> a is pinned to HASH but its context identity is HASH (changed: companions; interface unchanged)
  $ cp a.bak ../liba/a.jac && jacquard project check > /dev/null && echo clean
  clean

A dependency's own pins are verified transitively and cannot be overridden:

  $ mkdir ../libc && cat > ../libc/project.jqd <<'M'
  > (project-v1 (name "libc") (requires (core "0.2")) (namespace libc) (units "c.jac")
  >   (exports (term libc.big)) (deps (dep (as a) (path "../liba"))))
  > M
  $ echo 'libc.big(x) = liba.shout(x)' > ../libc/c.jac
  $ (cd ../libc && jacquard project pin > /dev/null)
  $ sed -i 's|(dep (as b) (path "../libb")|(dep (as c) (path "../libc")) (dep (as b) (path "../libb")|' project.jqd
  $ jacquard project pin --dep c | hashes
  c: unpinned -> HASH
  $ sed -i 's/by: 100/by: 300/' ../liba/a.jac
  $ jacquard project check 2>&1 | grep -o 'error\[E17..\].*' | sort -u
  error[E1710]: A dependency's pin does not match its context identity.
  error[E1712]: A transitive dependency's pin does not match its context identity.
  $ jacquard project check 2>&1 | grep 'app -> c -> a' | cut -c1-40
    Cause: dependency app -> c -> a is pin
  $ cp a.bak ../liba/a.jac

A project reaches only its direct dependencies' exports, never a dependency
of a dependency:

  $ mkdir ../app2 && echo 'liba.shout(1)' > ../app2/demo.jac
  $ printf '(project-v1 (name "app2") (requires (core "0.2")) (namespace app2) (deps (dep (as c) (path "../libc"))) (entries (run demo (units "demo.jac"))))' > ../app2/project.jqd
  $ (cd ../app2 && jacquard project pin > /dev/null && jacquard project run demo 2>&1 | grep -A1 error)
  $TESTCASE_ROOT/work/app2/demo.jac:1:1-11: error[E1705]: A name is not visible in this project.
    Cause: `liba.shout` belongs to project `liba`, which `app2` does not depend on directly
  $ echo 'app.go(1)' > demo.jac

Export selectors name the project's own definitions:

  $ sed -i 's/(term libb.twice)/(term libb.twice) (term libb.nothing)/' ../libb/project.jqd
  $ jacquard project check 2>&1 | grep -A1 'E1717'
  error[E1717]: An export selector names nothing the project defines.
    Cause: project `libb` exports (term libb.nothing), which its own units do not define
  $ sed -i 's/ (term libb.nothing)//' ../libb/project.jqd

Visible constructors must have one owner; a constructor is exempt from the
namespace but not from collisions:

  $ cp ../libb/b.jac b.bak && cp ../libb/project.jqd bm.bak
  $ echo 'type LibbBox = | LibaBox(size: Int)' >> ../libb/b.jac
  $ sed -i 's/(term libb.twice)/(term libb.twice) (type libb-box) (con liba-box)/; s/(type liba-box)/(type liba-box) (con liba-box)/' ../libb/project.jqd ../liba/project.jqd
  $ jacquard project pin > /dev/null 2>&1; jacquard project check 2>&1 | grep -A1 'E1731' | hashes
  error[E1731]: Two visible constructors share a name.
    Cause: constructor `liba-box` of type `liba-box` of project `liba` and constructor `liba-box` of type `libb-box` of project `libb` are both visible in project `app`
  $ cp b.bak ../libb/b.jac && cp bm.bak ../libb/project.jqd && sed -i 's/(type liba-box) (con liba-box)/(type liba-box)/' ../liba/project.jqd

Graph rules: cycles, overlapping namespaces, a dependency without a namespace,
and one namespace at two context identities:

  $ mkdir -p ../g/x ../g/y && cd ../g
  $ printf '(project-v1 (name "x") (requires (core "0.2")) (namespace x) (deps (dep (as y) (path "../y") (pin #%s))))' $(printf '0%.0s' $(seq 64)) > x/project.jqd
  $ printf '(project-v1 (name "y") (requires (core "0.2")) (namespace y) (deps (dep (as x) (path "../x") (pin #%s))))' $(printf '0%.0s' $(seq 64)) > y/project.jqd
  $ jacquard project check --project x 2>&1 | grep -A1 'E1713'
  error[E1713]: The project graph has a dependency cycle.
    Cause: dependency cycle: x -> y -> x
  $ sed -i 's/(namespace y)/(namespace x-y)/; s/ (deps.*))$/)/' y/project.jqd
  $ jacquard project check --project x 2>&1 | grep -A1 'E1707'
  error[E1707]: Two projects' namespaces overlap.
    Cause: namespace `x` is a boundary-prefix of namespace `x-y` in one project graph
  $ sed -i 's/ (namespace x-y)//' y/project.jqd
  $ jacquard project check --project x 2>&1 | grep -A1 'E1708' | sed 's|(.*project.jqd)|(PATH)|'
  error[E1708]: A depended-on project has no namespace.
    Cause: dependency x -> y (PATH) declares no namespace; a project that others depend on must declare one
  $ cd ../app && cp -r ../liba ../liba2 && sed -i 's/by: 100/by: 7/' ../liba2/a.jac
  $ sed -i 's|(dep (as b) (path "../libb")|(dep (as a2) (path "../liba2")) (dep (as b) (path "../libb")|' project.jqd
  $ jacquard project pin 2>&1 | grep -A1 'E1714' | sed -E 's/[^ ]*work/W/g; s/[0-9a-f]{64}/HASH/g'
  error[E1714]: One namespace appears at two context identities.
    Cause: namespace `liba` appears at two context identities: W/liba (HASH) and W/liba2 (HASH)

A callable's labels are not part of its identity, so two projects that bind
one identical body with different labels conflict when composed together:

  $ cd ../app && mkdir ../l1 ../l2 ../both
  $ printf '(project-v1 (name "l1") (requires (core "0.2")) (namespace l1) (units "f.jac") (exports (term l1.f)))' > ../l1/project.jqd
  $ echo 'l1.f(x, by: amount) = int.add(x, amount)' > ../l1/f.jac
  $ printf '(project-v1 (name "l2") (requires (core "0.2")) (namespace l2) (units "f.jac") (exports (term l2.f)))' > ../l2/project.jqd
  $ echo 'l2.f(x, plus: amount) = int.add(x, amount)' > ../l2/f.jac
  $ printf '(project-v1 (name "both") (requires (core "0.2")) (deps (dep (as a) (path "../l1")) (dep (as b) (path "../l2"))))' > ../both/project.jqd
  $ jacquard project pin --project ../both 2>&1 | grep -A1 'E1719' | hashes | cut -c1-70
  error[E1719]: A call-ABI companion conflicts across the project graph.
    Cause: project `l2` conflicts with the graph: callable HASH is alrea
