Local project manifests (PKG.1, docs/designs/project-structure.md §3). A
project is a directory holding project.jqd, a strict data value that is read
and validated but never evaluated.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ mkdir -p app/src && cd app && mkdir .git
  $ printf 'type AppStatus = | AppReady\napp.solve(x) = x\n' > src/model.jac
  $ echo '-- the report' > src/report.jac && echo '-- no tests yet' > tests.jac
  $ echo 'println(app.solve("ready"))' > demo.jac
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
  warning[W1703]: A transparent type is exported without its constructors.
    Cause: type `app-status` is exported without its constructors, which hides them by name only
    Next step: Declare it `opaque type` so that only its own project can construct or rebuild its values.
  library: 2 declarations checked
  entry suite (test): checked, 0 tests; requires nothing
  entry demo (run): checked; requires console
  $ (cd src && jacquard project check)
  $TESTCASE_ROOT/app/project.jqd: project-v1 manifest valid (2 units, 2 exports, 0 deps, 2 entries)
  warning[W1703]: A transparent type is exported without its constructors.
    Cause: type `app-status` is exported without its constructors, which hides them by name only
    Next step: Declare it `opaque type` so that only its own project can construct or rebuild its values.
  library: 2 declarations checked
  entry suite (test): checked, 0 tests; requires nothing
  entry demo (run): checked; requires console
  $ cd .. && jacquard project check --project app && cd app
  app/project.jqd: project-v1 manifest valid (2 units, 2 exports, 0 deps, 2 entries)
  warning[W1703]: A transparent type is exported without its constructors.
    Cause: type `app-status` is exported without its constructors, which hides them by name only
    Next step: Declare it `opaque type` so that only its own project can construct or rebuild its values.
  library: 2 declarations checked
  entry suite (test): checked, 0 tests; requires nothing
  entry demo (run): checked; requires console

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
  $ jacquard project check 2>&1 | grep -A1 'error\[E17'
  $TESTCASE_ROOT/app/project.jqd:1:48-63: error[E1701]: The project manifest has an unknown field.
    Cause: unknown field (license ...); free-form data belongs in (metadata ...)
  $ printf '(project-v1 (name "p") (requires (core "0.2")) (units "a.jac" "a.jac"))' > project.jqd
  $ jacquard project check 2>&1 | grep -A1 'error\[E17'
  $TESTCASE_ROOT/app/project.jqd:1:48-71: error[E1702]: The project manifest repeats an item that must be unique.
    Cause: a unit a.jac appears more than once
  $ printf '(project-v2 (name "p") (requires (core "0.2")))' > project.jqd
  $ jacquard project check 2>&1 | grep -A1 'error\[E17'
  $TESTCASE_ROOT/app/project.jqd:1:1-48: error[E1700]: The project manifest is malformed.
    Cause: unsupported manifest format project-v2; this tool reads project-v1
  $ printf '(project-v1 (name "p") (requires (core "9.0")))' > project.jqd
  $ jacquard project check 2>&1 | grep -A1 'error\[E17'
  error[E1704]: The running Core does not satisfy the project's requirement.
    Cause: the project requires Core 9.0 (same major, at least that minor); running 0.3.0

Without a manifest the search stops at the repository root:

  $ rm project.jqd && jacquard project check 2>&1 | grep -A1 'error\[E1735'
  error[E1735]: No project manifest was found or it could not be read.
    Cause: no project.jqd in $TESTCASE_ROOT/app or its parents (search stopped at $TESTCASE_ROOT/app)

A manifest that is not a regular file is refused without waiting on it, even
a FIFO that no writer will ever open:

  $ mkdir fifo && mkfifo fifo/project.jqd
  $ timeout 20 jacquard project check --project fifo 2>&1 | grep -o 'error\[E1735\]'
  error[E1735]
