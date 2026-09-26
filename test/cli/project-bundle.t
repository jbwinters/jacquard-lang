Bundles: the runnable, verifiable, importable form of a project (PKG.1,
docs/designs/project-structure.md §9).

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir -p work/liba work/app && cd work && mkdir .git
  $ hashes() { sed -E 's/[0-9a-f]{64}/HASH/g'; }
  $ cat > liba/project.jqd <<'M'
  > (project-v1 (name "liba") (requires (core "0.2")) (namespace liba) (units "a.jac")
  >   (exports (term liba.shout) (term liba.plus) (type liba-box)))
  > M
  $ cat > liba/a.jac <<'S'
  > type LibaBox = | LibaBox(value: Int)
  > liba.helper(x) = int.add(x, 100)
  > liba.shout(x) = LibaBox(liba.helper(x))
  > liba.plus(x, by: amount) = int.add(x, amount)
  > S
  $ cat > app/project.jqd <<'M'
  > (project-v1 (name "app") (requires (core "0.2")) (namespace app) (units "lib.jac")
  >   (deps (dep (as a) (path "../liba")))
  >   (entries (run demo (units "demo.jac")) (test suite (units "tests.jac"))))
  > M
  $ echo 'app.go(x) = liba.shout(x)' > app/lib.jac
  $ printf 'app.go(1)\n"two"\n' > app/demo.jac
  $ echo 'app.tests = Group("app", [Case("plus", fn () -> check.eq(liba.plus(1, by: 2), 3, int.eq, int.show, "sum"))])' > app/tests.jac
  $ cd app && jacquard project pin > /dev/null

A run entry's steps are independently checked thunks, so values of different
types keep their order; the record names each step, and the bytes depend only
on the inputs:

  $ jacquard project bundle -o ../app.bundle | hashes
  ../app.bundle: bundle HASH (8 objects, 1 companions)
  $ (cd ../app.bundle && find . -type f | sed -E 's/[0-9a-f]{64}/HASH/' | sort | uniq -c)
        1 ./bundle-v1.jqd
        1 ./companions.jqd
        2 ./contexts/HASH.jqd
        2 ./interfaces/HASH.jqd
        8 ./objects/HASH.jqd
        1 ./project.jqd
        1 ./provenance.jqd
  $ grep -A1 '(entries' ../app.bundle/bundle-v1.jqd | hashes
    (entries (run demo (steps #HASH #HASH) (grants)) (test suite (root test "app.tests" #HASH) (grants)))
    (objects 8)
  $ jacquard project bundle -o ../again.bundle > /dev/null && diff -r ../app.bundle ../again.bundle && echo identical
  identical

The bundle runs and tests from anywhere, verified before anything runs:

  $ (cd /tmp && jacquard project run --bundle "$OLDPWD/../app.bundle" demo)
  liba-box(101)
  "two"
  $ jacquard project test --bundle ../app.bundle --seed 1
  entry suite
  PASS app.tests/app/plus (1 check)
  1 passed, 0 failed, 0 skipped, 0 refused

Every tampering is refused before anything runs:

  $ tamper() { rm -rf ../t.bundle && cp -r ../app.bundle ../t.bundle; }
  $ tamper && sed -i 's/100/101/' ../t.bundle/objects/*.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1726]: A bundle object's hash does not match.
  $ tamper && rm ../t.bundle/objects/$(ls ../t.bundle/objects | head -1)
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1728]: A bundle closure is incomplete.
  $ tamper && sed -i 's/(arity 0)/(arity 1)/' ../t.bundle/interfaces/*.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1729]: A derived interface or context does not match the bundle record.
  $ tamper && for f in ../t.bundle/contexts/*.jqd; do sed -i 's/(core "[^"]*")/(core "9.9")/' $f; done
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1729]: A derived interface or context does not match the bundle record.
  $ tamper && sed -i -E 's/\(owner #[0-9a-f]{64}\)/(owner #0000000000000000000000000000000000000000000000000000000000000000)/' ../t.bundle/interfaces/*.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1727]: A bundle object's member ownership does not match.
  $ tamper && sed -i 's/(file "01-prim.jqd" "[0-9a-f]*")/(file "01-prim.jqd" "0")/' ../t.bundle/bundle-v1.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1720]: The bundle's prelude or Core does not match this tool.
  $ rm -rf ../t.bundle

A bundle refuses dynamic evaluation reachable from any root, including a
closure returned by an exported callable whose own authority is pure:

  $ echo 'app.make() = fn () -> `op:eval-code`(quote { 1 })' >> lib.jac
  $ sed -i 's/(namespace app)/(namespace app) (exports (term app.make))/' project.jqd
  $ jacquard project bundle -o ../eval.bundle 2>&1 | head -1; ls .. | grep -c eval.bundle
  error[E1721]: A bundle root can reach dynamic evaluation.
  0
  [1]
  $ sed -i '$d' lib.jac && sed -i 's/ (exports (term app.make))//' project.jqd

An output may not overlap an input:

  $ jacquard project bundle -o ../liba/x.bundle 2>&1 | head -1
  error[E1725]: An output path overlaps an input.

A second checkout depends on the bundle, calls an exported callable with its
labels, and still cannot reach a private helper; the bundle's pin is the
source project's context identity:

  $ (cd ../liba && jacquard project bundle -o ../liba.bundle > /dev/null)
  $ mkdir ../other && cd ../other
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as a) (bundle "../liba.bundle"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ echo 'liba.plus(1, by: 41)' > demo.jac
  $ jacquard project pin | cut -d' ' -f4 > pin.txt
  $ jacquard project interface --project ../liba | head -1 | cut -d' ' -f2 | diff - pin.txt && echo same
  same
  $ jacquard project run demo
  42
  $ echo 'liba.helper(1)' > demo.jac && jacquard project run demo 2>&1 | grep -A1 error
  $TESTCASE_ROOT/work/other/demo.jac:1:1-12: error[E1705]: A name is not visible in this project.
    Cause: `liba.helper` is private to project `liba`
