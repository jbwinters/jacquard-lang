Local project manifests (PKG.1, docs/designs/project-structure.md §3). A
project is a directory holding project.jqd, a strict data value that is read
and validated but never evaluated.

  $ export JACQUARD_PRELUDE=../../prelude
  $ mkdir -p app/src && cd app && mkdir .git
  $ cat > project.jqd <<'M'
  > (project-v1
  >   (metadata (license "Apache-2.0"))
  >   (name "demo-app")
  >   (requires (core "0.2"))
  >   (namespace app)
  >   (units "src/model.jac" "src/report.jac")
  >   (exports (type app-status) (term app.solve))
  >   (entries (test suite (units "tests.jac")) (run demo (units "demo.jac") (grants console) (native))))
  > M

Discovery finds the manifest from a subdirectory, and --project names it:

  $ jacquard project check
  $TESTCASE_ROOT/app/project.jqd: project-v1 manifest valid (2 units, 2 exports, 0 deps, 2 entries)
  $ (cd src && jacquard project check)
  $TESTCASE_ROOT/app/project.jqd: project-v1 manifest valid (2 units, 2 exports, 0 deps, 2 entries)
  $ cd .. && jacquard project check --project app && cd app
  app/project.jqd: project-v1 manifest valid (2 units, 2 exports, 0 deps, 2 entries)

The canonical spelling sorts fields, exports, entries and metadata, and keeps
unit order; --write replaces the file atomically and is idempotent:

  $ jacquard project fmt
  (project-v1
    (name "demo-app")
    (requires (core "0.2"))
    (namespace app)
    (units "src/model.jac" "src/report.jac")
    (exports (term app.solve) (type app-status))
    (entries (run demo (units "demo.jac") (grants console) (native)) (test suite (units "tests.jac")))
    (metadata (license "Apache-2.0")))
  $ jacquard project fmt --write && jacquard project fmt --write && cat project.jqd | head -3
  (project-v1
    (name "demo-app")
    (requires (core "0.2"))
  $ ls -a | grep -c tmp
  0
  [1]

Unknown fields fail closed, duplicates and budgets are refused:

  $ printf '(project-v1 (name "p") (requires (core "0.2")) (license "MIT"))' > project.jqd
  $ jacquard project check 2>&1 | grep -o 'error\[E17..\]'
  error[E1701]
  $ printf '(project-v1 (name "p") (requires (core "0.2")) (units "a.jac" "a.jac"))' > project.jqd
  $ jacquard project check 2>&1 | grep -o 'error\[E17..\]'
  error[E1702]
  $ printf '(project-v2 (name "p") (requires (core "0.2")))' > project.jqd
  $ jacquard project check 2>&1 | grep -o 'error\[E17..\]'
  error[E1700]
  $ printf '(project-v1 (name "p") (requires (core "9.0")))' > project.jqd
  $ jacquard project check 2>&1 | grep -o 'error\[E17..\]'
  error[E1704]

Without a manifest the search stops at the repository root:

  $ rm project.jqd && jacquard project check 2>&1 | grep -o 'error\[E1735\]'
  error[E1735]
