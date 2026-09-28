Local projects: output guards, version-control hygiene, composed diagnostics,
caching, and location independence for every command (PKG.1,
docs/designs/project-structure.md §6, §10, §11, §16).

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ export JACQUARD_RUNTIME=$PWD/../../runtime
  $ mkdir -p work/liba work/app && cd work && mkdir .git && root=$PWD
  $ cat > liba/project.jqd <<'M'
  > (project-v1 (name "liba") (requires (core "0.2")) (namespace liba) (units "a.jac")
  >   (exports (term liba.shout)))
  > M
  $ printf 'liba.helper(x) = int.add(x, 100)\nliba.shout(x) = liba.helper(x)\n' > liba/a.jac
  $ mkdir libb && printf '(project-v1 (name "libb") (requires (core "0.2")) (namespace libb) (units "b.jac") (exports (term libb.twice)))' > libb/project.jqd
  $ echo 'libb.twice(x) = int.add(x, x)' > libb/b.jac
  $ cat > app/project.jqd <<'M'
  > (project-v1 (name "app") (requires (core "0.2")) (namespace app) (units "lib.jac")
  >   (deps (dep (as a) (path "../liba")) (dep (as b) (path "../libb")))
  >   (entries (run demo (units "demo.jac") (native)) (test suite (units "tests.jac"))))
  > M
  $ printf 'app.helper(x) = int.add(x, 7)\napp.go(x) = (liba.shout(x), app.helper(x))\n' > app/lib.jac
  $ echo 'app.go(1)' > app/demo.jac
  $ echo 'app.tests = Case("go", fn () -> match app.go(0) { | (a, b) -> check.eq(int.add(a, b), 107, int.eq, int.show, "go") })' > app/tests.jac
  $ cd app && jacquard project pin > /dev/null

The two libraries' private helpers stay distinct natively as well:

  $ jacquard project build demo -o ../demo.bin > /dev/null && ../demo.bin
  (101, 8)

An output may not overwrite an input, a unit of a dependency, or land inside a
dependency (E1725); a build inside the project's own directory is fine:

  $ jacquard project build demo -o lib.jac 2>&1 | head -2
  error[E1725]: An output path overlaps an input.
    Cause: native output $TESTCASE_ROOT/work/app/lib.jac overlaps the input $TESTCASE_ROOT/work/app/lib.jac
  $ head -1 lib.jac
  app.helper(x) = int.add(x, 7)
  $ jacquard project build demo -o ../liba/a.jac 2>&1 | grep -o 'error\[E1725\]'
  error[E1725]
  $ head -1 ../liba/a.jac
  liba.helper(x) = int.add(x, 100)
  $ jacquard project test --seed 1 --cache-dir ../liba/cache 2>&1 | grep -o 'error\[E1725\].*'
  error[E1725]: An output path overlaps an input.
  $ ls ../liba
  a.jac
  project.jqd

The Warp result cache lives under the project's .jacquard/ and is reused:

  $ jacquard project test --seed 1 | tail -1
  cache: 0 hit, 1 ran
  $ jacquard project test --seed 1 | tail -1
  cache: 1 hit, 0 ran

`test` and `build` give the same results from the project, a parent, and an
unrelated directory, with an empty HOME:

  $ export HOME=$(mktemp -d)
  $ (cd .. && jacquard project test --project app --seed 1 --no-cache | tail -1)
  1 passed, 0 failed, 0 skipped, 0 refused
  $ (cd /tmp && jacquard project test --project "$root/app" --seed 1 --no-cache | tail -1)
  1 passed, 0 failed, 0 skipped, 0 refused
  $ (cd /tmp && jacquard project build --project "$root/app" demo -o "$root/far.bin" > /dev/null) && "$root/far.bin"
  (101, 8)
  $ ls "$HOME" | wc -l
  0

The order of a consumer's dependencies is not part of any pin, its context,
or its identities:

  $ jacquard project interface | head -1 > before.ctx && jacquard project hash demo > before.hash
  $ grep -o '(dep (as a)[^)]*)[^)]*))' project.jqd > dep-a && grep -o '(dep (as b)[^)]*)[^)]*))' project.jqd > dep-b
  $ printf '(project-v1 (name "app") (requires (core "0.2")) (namespace app) (units "lib.jac")\n  (deps %s %s)\n  (entries (run demo (units "demo.jac") (native)) (test suite (units "tests.jac"))))\n' "$(cat dep-b)" "$(cat dep-a)" > project.jqd
  $ grep -o '(deps (dep (as .)' project.jqd
  (deps (dep (as b)
  $ jacquard project pin --dry-run | sed -E 's/[0-9a-f]{64}/HASH/'
  b: HASH (unchanged)
  a: HASH (unchanged)
  $ jacquard project interface | head -1 | cmp - before.ctx && jacquard project hash demo | cmp - before.hash && echo identical
  identical

A pin that cannot write leaves the old manifest intact:

  $ cp project.jqd before.jqd && sed -i 's/(pin #[0-9a-f]*)//' project.jqd && cp project.jqd unpinned.jqd
  $ chmod a-w . && jacquard project pin > /dev/null 2>&1; echo "exit $?"; chmod u+w .
  exit 1
  $ cmp project.jqd unpinned.jqd && echo intact
  intact
  $ cp before.jqd project.jqd

Project state belongs to one checkout; tracking it is W1701:

  $ git init -q && git add -f .jacquard && jacquard project check 2>&1 | grep -A1 'W1701' | sed 's/[0-9]* file(s)/N file(s)/'
  warning[W1701]: Local project state is tracked by version control.
    Cause: N file(s) under $TESTCASE_ROOT/work/app/.jacquard are tracked by version control, e.g. .jacquard/build/demo/recipe.jqd
  $ rm -rf .git

A definition checked against a signature in another unit names both files
(W1702 beside the checker's error):

  $ mkdir ../split && cd ../split
  $ printf '(project-v1 (name "s") (requires (core "0.2")) (namespace s) (units "sig.jac" "def.jac"))' > project.jqd
  $ printf 's.f : (Int) ->{} Text\n' > sig.jac && printf 's.f(x) = x\n' > def.jac
  $ jacquard project check 2>&1 | grep -o '[a-z]*\.jac:[0-9:-]*: [a-z]*\[[EW][0-9]*\]'
  def.jac:1:1-11: error[E0804]
  sig.jac:1:7-22: warning[W1702]
