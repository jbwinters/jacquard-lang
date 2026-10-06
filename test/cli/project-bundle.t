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
        1 ./bundle-v2.jqd
        1 ./companions.jqd
        2 ./contexts/HASH.jqd
        2 ./interfaces/HASH.jqd
        8 ./objects/HASH.jqd
        1 ./project.jqd
        1 ./provenance.jqd
  $ grep -A1 '(entries' ../app.bundle/bundle-v2.jqd | hashes
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
  error[E1728]: A bundle closure is incomplete.
  $ tamper && sed -i 's/(file "01-prim.jqd" "[0-9a-f]*")/(file "01-prim.jqd" "0")/' ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1720]: The bundle's prelude or Core does not match this tool.
  $ mkdir ../extra && printf '(project-v1 (name "extra") (requires (core "0.2")) (namespace extra) (units "e.jac") (exports (term extra.run)))' > ../extra/project.jqd
  $ echo 'extra.run() = `op:eval-code`(quote { 1 })' > ../extra/e.jac
  $ (cd ../extra && jacquard project bundle -o ../extra.bundle 2>&1 | head -1)
  error[E1721]: A bundle root can reach dynamic evaluation.
  $ echo 'extra.run() = 7' > ../extra/e.jac && (cd ../extra && jacquard project bundle -o ../extra.bundle > /dev/null)
  $ tamper && cp ../extra.bundle/objects/*.jqd ../t.bundle/objects/
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | grep -o 'error\[E17..\].*\|is not reachable.*' | head -2
  error[E1728]: A bundle closure is incomplete.
  is not reachable from any root; a bundle carries its closure only
  $ tamper && mv ../t.bundle/objects ../objects.real && ln -s ../objects.real ../t.bundle/objects
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | grep -o 'error\[E1735\].*\|objects is not a directory'
  error[E1735]: The bundle cannot be read.
  objects is not a directory
  $ rm -rf ../objects.real
  $ tamper && S=$(grep -o 'steps #[0-9a-f]*' ../t.bundle/bundle-v2.jqd | cut -d'#' -f2)
  $ T=$(grep -o '(root test "app.tests" #[0-9a-f]*' ../t.bundle/bundle-v2.jqd | cut -d'#' -f2)
  $ sed -i "s/steps #$S/steps #$T/" ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | grep -o 'error\[E1728\]\|is not a thunk'
  error[E1728]
  is not a thunk
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

TYPE.1 (docs/designs/abstract-types.md §2.4): a bundle-v2 record names the
namespace of every context it carries, and verification checks each one
(E1739): a relabelled or missing namespace, or a root namespace that differs
from project.jqd, is refused:

  $ grep -o '(namespace #[0-9a-f]* [a-z]*)' ../app.bundle/bundle-v2.jqd | hashes | sort
  (namespace #HASH app)
  (namespace #HASH liba)
  $ tamper && sed -i 's/ liba)/ libz)/' ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -2 | hashes
  error[E1739]: Recorded namespaces conflict with the contexts they name.
    Cause: context HASH exports `liba-box`, which is outside its namespace `libz`
  $ tamper && sed -i -E 's/ ?\(namespace #[0-9a-f]+ liba\)//' ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -2 | hashes
  error[E1739]: Recorded namespaces conflict with the contexts they name.
    Cause: carried context HASH records no namespace
  $ tamper && sed -i -E 's/(\(namespace #[0-9a-f]+) app\)/\1 appz)/' ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -2 | hashes
  error[E1739]: Recorded namespaces conflict with the contexts they name.
    Cause: the root context's recorded namespace differs from project.jqd

A bundle-v1 bundle records no namespaces: it is still read when it carries no
dependency context, and refused when it does (E1735):

  $ tamper && (cd ../t.bundle && sed -e 's/^(bundle-v2/(bundle-v1/' -e '/(namespaces/d' bundle-v2.jqd > bundle-v1.jqd && rm bundle-v2.jqd)
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -2
  error[E1735]: The bundle cannot be read.
    Cause: a bundle-v1 bundle carries dependency contexts but records no namespaces; rebuild it as bundle-v2
  $ rm -rf ../l1.bundle && cp -r ../liba.bundle ../l1.bundle
  $ (cd ../l1.bundle && sed -e 's/^(bundle-v2/(bundle-v1/' -e '/(namespaces/d' bundle-v2.jqd > bundle-v1.jqd && rm bundle-v2.jqd)
  $ sed -i 's/liba.bundle/l1.bundle/' project.jqd && jacquard project pin > /dev/null
  $ echo 'liba.plus(1, by: 41)' > demo.jac && jacquard project run demo
  42
  $ sed -i 's/l1.bundle/liba.bundle/' project.jqd && jacquard project pin > /dev/null

A carried namespace counts as a graph namespace: a root without a namespace
cannot declare inside it, even when only a bundle carries it (E1737), and
another context in it at a second identity is refused (E1714):

  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as p) (bundle "../app.bundle"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ echo '1' > demo.jac
  $ jacquard project pin > /dev/null && jacquard project run demo
  1
  $ printf 'type LibaFake = | LibaFake\n1\n' > demo.jac
  $ jacquard project check 2>&1 | grep -A1 'error\[E1737\]' | sed 's/^.*error/error/'
  error[E1737]: A project declares a type or effect inside another project's namespace.
    Cause: type `liba-fake` ($TESTCASE_ROOT/work/other/demo.jac) is inside namespace `liba`, which a context in bundle $TESTCASE_ROOT/work/app.bundle owns
  $ echo '1' > demo.jac
  $ rm -rf ../liba2 && cp -r ../liba ../liba2 && echo 'liba.extra(x) = x' >> ../liba2/a.jac
  $ sed -i 's/(exports /(exports (term liba.extra) /' ../liba2/project.jqd
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as p) (bundle "../app.bundle")) (dep (as b) (path "../liba2"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ jacquard project pin 2>&1 | grep -o 'error\[E1714\].*'
  error[E1714]: One namespace appears at two context identities.

A bundle is self-contained: an object it lacks is refused even when an earlier
import already put that object in the session (E1728):

  $ rm -rf ../t.bundle && cp -r ../app.bundle ../t.bundle
  $ for f in ../liba.bundle/objects/*.jqd; do rm -f ../t.bundle/objects/$(basename $f); done
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as a) (bundle "../liba.bundle")) (dep (as p) (bundle "../t.bundle"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ jacquard project pin 2>&1 | grep -o 'error\[E17[0-9]*\].*' | head -1
  error[E1728]: A bundle closure is incomplete.

A namespace recorded for a context the bundle does not carry is refused
(E1739), and a carried namespace is a graph namespace for the prefix rule too
(E1707):

  $ tamper && sed -i -E 's/\(namespaces /(namespaces (namespace #0000000000000000000000000000000000000000000000000000000000000000 ghost) /' ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -2 | hashes
  error[E1739]: Recorded namespaces conflict with the contexts they name.
    Cause: a namespace is recorded for unknown context HASH
  $ mkdir -p ../libax && printf '(project-v1 (name "libax") (requires (core "0.2")) (namespace liba-x) (units "x.jac") (exports (term liba-x.one)))' > ../libax/project.jqd
  $ echo 'liba-x.one = 1' > ../libax/x.jac
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as p) (bundle "../app.bundle")) (dep (as x) (path "../libax"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ jacquard project pin 2>&1 | grep -o 'error\[E1707\].*'
  error[E1707]: Two projects' namespaces overlap.

A bundle-v1 bundle cannot carry an opaque declaration (E1735):

  $ mkdir -p ../sealed && printf '(project-v1 (name "sealed") (requires (core "0.2")) (namespace sealed) (units "s.jac") (exports (type sealed-coin) (term sealed.heads)))' > ../sealed/project.jqd
  $ printf 'opaque type SealedCoin = | SealedHeads | SealedTails\nsealed.heads = SealedHeads\n' > ../sealed/s.jac
  $ (cd ../sealed && jacquard project bundle -o ../sealed.bundle > /dev/null)
  $ (cd ../sealed.bundle && sed -e 's/^(bundle-v2/(bundle-v1/' -e '/(namespaces/d' bundle-v2.jqd > bundle-v1.jqd && rm bundle-v2.jqd)
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as s) (bundle "../sealed.bundle"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ jacquard project pin 2>&1 | grep -A1 'error\[E1735\]'
  error[E1735]: The bundle cannot be read.
    Cause: a bundle-v1 bundle cannot carry an opaque declaration

Two copies of one project are one context: a bundle records it once and loads
again; and a consumer of a bundle can itself be bundled, carrying the contexts
its dependency bundle carries:

  $ rm -rf ../libacopy && cp -r ../liba ../libacopy
  $ printf '(project-v1 (name "twice") (requires (core "0.2")) (namespace twice) (units "t.jac") (deps (dep (as a) (path "../liba")) (dep (as c) (path "../libacopy"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ echo 'twice.go(x) = liba.plus(x, by: 1)' > t.jac && echo 'twice.go(1)' > demo.jac
  $ jacquard project pin > /dev/null && jacquard project bundle -o ../twice.bundle > /dev/null
  $ grep -o '(namespace #[0-9a-f]* [a-z]*)' ../twice.bundle/bundle-v2.jqd | hashes | sort
  (namespace #HASH liba)
  (namespace #HASH twice)
  $ jacquard project run --bundle ../twice.bundle demo
  2
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (namespace other) (deps (dep (as p) (bundle "../app.bundle"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ echo '1' > demo.jac && rm -f t.jac
  $ jacquard project pin > /dev/null && jacquard project bundle -o ../again2.bundle > /dev/null
  $ ls ../again2.bundle/contexts | wc -l
  3
  $ jacquard project run --bundle ../again2.bundle demo
  1

A bundle is verified on its own too. Two of its contexts in one namespace
(E1714), or one namespace a boundary-prefix of another (E1707), are refused
before any graph is composed:

  $ tamper && sed -i 's/ liba)/ app)/' ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1714]: One namespace appears at two context identities.
  $ tamper && sed -i 's/ liba)/ app-x)/' ../t.bundle/bundle-v2.jqd
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1707]: Two projects' namespaces overlap.

A recorded export of a sealed constructor is refused (E1736):

  $ (cd ../sealed && jacquard project bundle -o ../sealed2.bundle > /dev/null)
  $ F=$(ls ../sealed2.bundle/interfaces/*.jqd) && perl -0pi -e 's/\(hidden\n  (#[0-9a-f]+)\n  \(owner (#[0-9a-f]+)\)\)/(export\n  con\n  sealed-heads\n  $1\n  (owner $2)\n  (signature "x"))/' $F
  $ jacquard project run --bundle ../sealed2.bundle demo 2>&1 | head -1
  error[E1736]: A bundle exports a sealed constructor.

Every recorded export must be one of the bundle's own objects: an unused
dependency export removed from a bundle is not borrowed from an earlier import
(E1728). An export that reaches eval-code refuses bundling even when the root
never calls it (E1721):

  $ mkdir -p ../libu ../appu && printf '(project-v1 (name "libu") (requires (core "0.2")) (namespace libu) (units "u.jac") (exports (term libu.used) (term libu.spare)))' > ../libu/project.jqd
  $ printf 'libu.used(x) = x\nlibu.spare(x) = int.add(x, 7)\n' > ../libu/u.jac
  $ printf '(project-v1 (name "appu") (requires (core "0.2")) (namespace appu) (units "a.jac") (deps (dep (as u) (path "../libu"))) (entries (run demo (units "demo.jac"))))' > ../appu/project.jqd
  $ echo 'appu.go(x) = libu.used(x)' > ../appu/a.jac && echo 'appu.go(5)' > ../appu/demo.jac
  $ (cd ../libu && jacquard project bundle -o ../libu.bundle > /dev/null)
  $ (cd ../appu && jacquard project pin > /dev/null && jacquard project bundle -o ../appu.bundle > /dev/null)
  $ rm "$(grep -l 'libu.spare' ../appu.bundle/objects/*.jqd)"
  $ N=$(ls ../appu.bundle/objects | wc -l) && sed -i "s/(objects [0-9]*)/(objects $N)/" ../appu.bundle/bundle-v2.jqd
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as l) (bundle "../libu.bundle")) (dep (as p) (bundle "../appu.bundle"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ echo '1' > demo.jac && jacquard project pin 2>&1 | grep -o 'error\[E1728\].*'
  error[E1728]: A bundle closure is incomplete.
  $ echo 'libu.spare(x) = `op:eval-code`(quote { x })' > ../libu/u.jac && sed -i 's/libu.spare(x) = /libu.used(x) = x\nlibu.spare(x) = /' ../libu/u.jac
  $ (cd ../appu && jacquard project pin > /dev/null && jacquard project bundle -o ../appu-eval.bundle 2>&1 | head -1)
  error[E1721]: A bundle root can reach dynamic evaluation.

Two source projects with one context identity but different namespaces (no
exports, the same dependencies) compose as source, but a bundle records one
namespace per context, so bundling them is refused (E1739):

  $ mkdir -p ../n1 ../n2
  $ printf '(project-v1 (name "n1") (requires (core "0.2")) (namespace nsone) (units "x.jac"))' > ../n1/project.jqd && echo 'nsone.x = 1' > ../n1/x.jac
  $ printf '(project-v1 (name "n2") (requires (core "0.2")) (namespace nstwo) (units "x.jac"))' > ../n2/project.jqd && echo 'nstwo.x = 1' > ../n2/x.jac
  $ printf '(project-v1 (name "other") (requires (core "0.2")) (deps (dep (as a) (path "../n1")) (dep (as b) (path "../n2"))) (entries (run demo (units "demo.jac"))))' > project.jqd
  $ jacquard project pin > /dev/null && jacquard project run demo
  1
  $ jacquard project bundle -o ../n.bundle 2>&1 | grep -o 'error\[E1739\].*'
  error[E1739]: Recorded namespaces conflict with the contexts they name.

A carried context must be a dependency of the bundle's own context; an orphan
context and its objects are refused (E1729):

  $ tamper && cp ../libu.bundle/contexts/*.jqd ../t.bundle/contexts/ && cp ../libu.bundle/interfaces/*.jqd ../t.bundle/interfaces/ && cp ../libu.bundle/objects/*.jqd ../t.bundle/objects/
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -2 | hashes
  error[E1729]: A derived interface or context does not match the bundle record.
    Cause: context HASH is not a dependency of the bundle's own context

An export whose recorded owner is present in the bundle but is not the
declaration it belongs to is refused (E1727):

  $ tamper && F=$(grep -l 'liba-box' ../t.bundle/interfaces/*.jqd) && perl -0pi -e 'my ($own) = /liba-box\n  #[0-9a-f]+\n  \(owner (#[0-9a-f]+)\)/; my ($a) = grep { $_ ne $own } /\(owner (#[0-9a-f]+)\)/g; s/(liba-box\n  #[0-9a-f]+\n  \(owner )#[0-9a-f]+/$1$a/' $F
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1727]: A bundle object's member ownership does not match.

Two dependencies may export one identity under different names; the bundle
carries the object once, and each context's recorded name still verifies:

  $ mkdir -p ../alia ../alib ../aliapp
  $ printf '(project-v1 (name "alia") (requires (core "0.2")) (namespace alia) (units "a.jac") (exports (term alia.f)))' > ../alia/project.jqd && echo 'alia.f(x) = int.add(x, 712345)' > ../alia/a.jac
  $ printf '(project-v1 (name "alib") (requires (core "0.2")) (namespace alib) (units "b.jac") (exports (term alib.f)))' > ../alib/project.jqd && echo 'alib.f(x) = int.add(x, 712345)' > ../alib/b.jac
  $ printf '(project-v1 (name "aliapp") (requires (core "0.2")) (namespace aliapp) (units "l.jac") (deps (dep (as a) (path "../alia")) (dep (as b) (path "../alib"))) (entries (run demo (units "demo.jac"))))' > ../aliapp/project.jqd
  $ echo 'aliapp.go(x) = alib.f(alia.f(x))' > ../aliapp/l.jac && echo 'aliapp.go(0)' > ../aliapp/demo.jac
  $ (cd ../aliapp && jacquard project pin > /dev/null && jacquard project bundle -o ../ali.bundle > /dev/null && jacquard project run --bundle ../ali.bundle demo)
  1424690

A term named after a type the bundle does not carry still lies inside its
namespace; the bundle rule is no stricter than the source rule:

  $ mkdir -p ../tn ../tnapp
  $ printf '(project-v1 (name "tn") (requires (core "0.2")) (namespace tn) (units "t.jac") (exports (term tn-box.answer)))' > ../tn/project.jqd
  $ printf 'type TnBox = | TnBox\ntn-box.answer() = 42\n' > ../tn/t.jac
  $ printf '(project-v1 (name "tnapp") (requires (core "0.2")) (namespace tnapp) (units "l.jac") (deps (dep (as t) (path "../tn"))) (entries (run demo (units "demo.jac"))))' > ../tnapp/project.jqd
  $ echo 'tnapp.go() = tn-box.answer()' > ../tnapp/l.jac && echo 'tnapp.go()' > ../tnapp/demo.jac
  $ (cd ../tnapp && jacquard project pin > /dev/null && jacquard project bundle -o ../tn.bundle > /dev/null && jacquard project run --bundle ../tn.bundle demo)
  42

One recorded interface cannot name an export twice (E1729):

  $ tamper && F=$(grep -l 'liba.plus' ../t.bundle/interfaces/*.jqd) && perl -0pi -e 's/(\(export\n  term\n  liba\.plus\n.*?\)\)\n)/$1$1/s' $F && grep -c 'liba.plus' $F
  2
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -2 | hashes
  error[E1729]: A derived interface or context does not match the bundle record.
    Cause: interface HASH records `liba.plus` twice

A recorded type, effect, constructor or operation export carries its
declaration's own name, which is part of its identity; a renamed one is refused
(E1729). One name bound to two identities is refused too, while one name in
two kinds (a type and its constructor) verifies:

  $ tamper && F=$(grep -l 'liba-box' ../t.bundle/interfaces/*.jqd) && sed -i 's/^  liba-box$/  liba-other/' $F && grep -c 'liba-other' $F
  1
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1729]: A derived interface or context does not match the bundle record.
  $ tamper && F=$(grep -l 'liba.plus' ../t.bundle/interfaces/*.jqd) && perl -0pi -e 's/(\(export\n  term\n  liba\.shout\n  #[0-9a-f]+\n.*?\)\)\n)/my $b=$1; my $c=$b; $c =~ s#liba\.shout#liba.plus#; "$b$c"/se' $F && grep -c 'liba.plus' $F
  2
  $ jacquard project run --bundle ../t.bundle demo 2>&1 | head -1
  error[E1729]: A derived interface or context does not match the bundle record.
  $ mkdir -p ../twokind ../twokindapp
  $ printf '(project-v1 (name "twokind") (requires (core "0.2")) (namespace twokind) (units "k.jac") (exports (type twokind-box) (con twokind-box)))' > ../twokind/project.jqd
  $ echo 'type TwokindBox = | TwokindBox(value: Int)' > ../twokind/k.jac
  $ printf '(project-v1 (name "twokindapp") (requires (core "0.2")) (namespace twokindapp) (units "l.jac") (deps (dep (as k) (path "../twokind"))) (entries (run demo (units "demo.jac"))))' > ../twokindapp/project.jqd
  $ echo 'twokindapp.go(x) = TwokindBox(x)' > ../twokindapp/l.jac && echo 'twokindapp.go(3)' > ../twokindapp/demo.jac
  $ (cd ../twokindapp && jacquard project pin > /dev/null && jacquard project bundle -o ../twokind.bundle > /dev/null && jacquard project run --bundle ../twokind.bundle demo)
  twokind-box(3)
