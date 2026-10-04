Opaque types in projects (TYPE.1, docs/designs/abstract-types.md §2.3–§2.5).
A library seals its type's constructors; its own entries may still use them.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir -p work/prob work/app && cd work && mkdir .git
  $ cat > prob/project.jqd <<'M'
  > (project-v1 (name "prob") (requires (core "0.2")) (namespace prob) (units "p.jac")
  >   (exports (type prob-score) (term prob.make) (term prob-score.value))
  >   (entries (run selftest (units "selftest.jac"))))
  > M
  $ cat > prob/p.jac <<'S'
  > opaque type ProbScore = | ProbScore(value: Int)
  > prob.make(n) = ProbScore(int.max(0, n))
  > S
  $ echo 'prob-score.value(ProbScore(7))' > prob/selftest.jac
  $ cat > app/project.jqd <<'M'
  > (project-v1 (name "app") (requires (core "0.2")) (namespace app) (units "lib.jac")
  >   (deps (dep (as p) (path "../prob")))
  >   (entries (run demo (units "demo.jac"))))
  > M
  $ echo 'app.go(x) = prob-score.value(prob.make(x))' > app/lib.jac
  $ echo 'app.go(-5)' > app/demo.jac

The owner's entries construct and match its sealed type, and an opaque type
gets an accessor but no setter:

  $ cd prob
  $ jacquard project run selftest
  7
  $ cd ../app && jacquard project pin > /dev/null

A consumer builds values only through the owner's functions:

  $ jacquard project run demo
  0
  $ echo 'app.forged = ProbScore(500)' >> lib.jac
  $ jacquard project check 2>&1 | grep -A1 'error'
  $TESTCASE_ROOT/work/app/lib.jac:2:14-23: error[E1705]: A name is not visible in this project.
    Cause: `prob-score` is private to project `prob`
  $ echo 'app.go(x) = prob-score.value(prob.make(x))' > lib.jac

An explicit identity is refused like a name (E1709):

  $ H=$(cd ../prob && jacquard project interface | tr '\n' ' ' | grep -o 'hidden *#[0-9a-f]*' | head -1 | cut -d'#' -f2)
  $ printf '(defterm ((binding app.forged () (ref #%s con))))\n' "$H" > forge.jqd
  $ sed -i 's/(units "lib.jac")/(units "lib.jac" "forge.jqd")/' project.jqd
  $ jacquard project check 2>&1 | grep -o 'error\[E1709\].*'
  error[E1709]: An explicit identity is not visible in this project.
  $ sed -i 's/ "forge.jqd"//' project.jqd && rm forge.jqd

An opaque type exported without its constructors is sealed, not hidden by name,
so it draws no W1703; a manifest cannot export a sealed constructor (E1736):

  $ cd ../prob
  $ jacquard project check 2>&1 | grep -c W1703
  0
  [1]
  $ sed -i 's/(term prob.make)/(term prob.make) (con prob-score)/' project.jqd
  $ jacquard project check 2>&1 | grep -A1 'error'
  error[E1736]: A manifest exports a sealed constructor.
    Cause: project `prob` exports (con prob-score), a constructor of an opaque type, which stays sealed to its own project
  $ sed -i 's/ (con prob-score)//' project.jqd

A root without a namespace cannot declare a type inside a dependency's
namespace, and neither can an entry unit (E1737):

  $ cd ../app && jacquard project pin > /dev/null
  $ sed -i 's/ (namespace app)//' project.jqd
  $ echo 'type ProbScore = | ProbScore(value: Int)' >> lib.jac
  $ jacquard project check 2>&1 | grep -A1 'error'
  $TESTCASE_ROOT/work/app/lib.jac:2:1-41: error[E1737]: A project declares a type or effect inside another project's namespace.
    Cause: type `prob-score` ($TESTCASE_ROOT/work/app/lib.jac) is inside namespace `prob`, which project `prob` owns
  $ echo 'opaque type ProbScore = | ProbScore(value: Int)' > lib.jac
  $ jacquard project check 2>&1 | grep -o 'error\[E1737\].*'
  error[E1737]: A project declares a type or effect inside another project's namespace.
  $ echo 'app.go(x) = prob-score.value(prob.make(x))' > lib.jac
  $ sed -i 's/(name "app")/(name "app") (namespace app)/' project.jqd
  $ printf 'type ProbFake = | ProbFake\napp.go(-5)\n' > demo.jac
  $ jacquard project check 2>&1 | grep -A1 'error'
  $TESTCASE_ROOT/work/app/demo.jac:1:1-27: error[E1737]: A project declares a type or effect inside another project's namespace.
    Cause: type `prob-fake` ($TESTCASE_ROOT/work/app/demo.jac) is inside namespace `prob`, which project `prob` owns

A transparent type exported without its constructors, or its setter, warns
that the constructors are hidden by name only (W1703):

  $ cd ../prob
  $ sed -i 's/^opaque type/type/' p.jac
  $ sed -i 's/(term prob-score.value)/(term prob-score.value) (term prob-score.with-value)/' project.jqd
  $ jacquard project check 2>&1 | grep -A1 'warning'
  warning[W1703]: A transparent type is exported without its constructors.
    Cause: type `prob-score` is exported without its constructors, which hides them by name only
  --
  warning[W1703]: A transparent type is exported without its constructors.
    Cause: the exported setter `prob-score.with-value` rebuilds a value of `prob-score`, whose constructors are not exported

A repeated prelude declaration is owned by no project, so it is not a
re-declaration, even inside a dependency's namespace; a changed declaration
of the same name is (E1737):

  $ cd ../.. && mkdir -p gov app2 && cd gov
  $ cat > project.jqd <<'M'
  > (project-v1 (name "gov") (requires (core "0.2")) (namespace governance) (units "g.jac")
  >   (exports (term governance.ping)))
  > M
  $ echo 'governance.ping(x) = x' > g.jac
  $ cd ../app2
  $ cat > project.jqd <<'M'
  > (project-v1 (name "app2") (requires (core "0.2")) (units "lib.jac")
  >   (deps (dep (as g) (path "../gov"))))
  > M
  $ echo 'type GovernanceVersion = | GovernanceV0' > lib.jac
  $ jacquard project pin > /dev/null
  $ jacquard project check | tail -1
  library: 1 declarations checked
  $ echo 'type GovernanceVersion = | GovernanceV1' > lib.jac
  $ jacquard project check 2>&1 | grep -o 'error\[E1737\].*'
  error[E1737]: A project declares a type or effect inside another project's namespace.
  $ echo 'once effect GovernanceAsk where { ask : () -> Int }' > lib.jac
  $ jacquard project check 2>&1 | grep -A1 'error\[E1737\]' | sed 's/^.*error/error/'
  error[E1737]: A project declares a type or effect inside another project's namespace.
    Cause: effect `governance-ask` ($TESTCASE_ROOT/app2/lib.jac) is inside namespace `governance`, which project `governance` owns

Each file `jacquard tiers` loads is its own defining scope (E0315):

  $ cd .. && cat > owner.jqd <<'S'
  > (deftype tier-coin () (opaque) (con tier-heads) (con tier-tails))
  > (defterm ((binding tier-flip () (lam ((pvar c)) (match (var c) (clause (pcon tier-heads) (var tier-tails)) (clause (pcon tier-tails) (var tier-heads)))))))
  > S
  $ echo '(defterm ((binding tier-forged () (var tier-heads))))' > consumer.jqd
  $ jacquard tiers owner.jqd > /dev/null
  $ jacquard tiers owner.jqd consumer.jqd 2>&1 | grep -A1 'error\[E0315\]' | sed -E 's/[0-9a-f]{64}/HASH/; s/^.*error/error/'
  error[E0315]: A sealed constructor is used outside its defining scope.
    Cause: constructor `tier-heads` (HASH) belongs to the opaque type `tier-coin`, which this source does not declare

Entries may declare their own types, transparent or opaque, outside the
project's namespace. A bundle carries them, and verification attributes an
unprefixed type to the bundle's own root:

  $ cd ../.. && mkdir -p ent && cd ent
  $ printf '(project-v1 (name "ent") (requires (core "0.2")) (namespace ent) (units "l.jac") (exports (term ent.one)) (entries (run demo (units "demo.jac")) (test suite (units "t.jac"))))' > project.jqd
  $ echo 'ent.one = 1' > l.jac
  $ printf 'type Local = | Local(value: Int)\nopaque type Hidden = | Hidden(value: Int)\nlocal.value(Local(ent.one))\nhidden.value(Hidden(2))\n' > demo.jac
  $ printf 'type Fixture = | Fixture(value: Int)\nent.tests = Group("ent", [Case("fixture", fn () -> check.eq(fixture.value(Fixture(3)), 3, int.eq, int.show, "fixture"))])\n' > t.jac
  $ jacquard project bundle -o ../ent.bundle > /dev/null && jacquard project run --bundle ../ent.bundle demo
  1
  2
  $ jacquard project test --bundle ../ent.bundle suite 2>&1 | tail -1
  1 passed, 0 failed, 0 skipped, 0 refused

A root without a namespace owns its opaque types:

  $ cd .. && mkdir -p nons && cd nons
  $ printf '(project-v1 (name "nons") (requires (core "0.2")) (units "l.jac") (entries (run demo (units "demo.jac"))))' > project.jqd
  $ printf 'opaque type Coin = | Heads | Tails\nflip(c) = match c { | Heads -> Tails | Tails -> Heads }\n' > l.jac
  $ echo 'flip(Heads)' > demo.jac
  $ jacquard project bundle -o ../nons.bundle > /dev/null && jacquard project run --bundle ../nons.bundle demo
  tails
