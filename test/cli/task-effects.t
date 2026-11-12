Every task (an async.spawn child or an async.scope body) runs on a fresh
continuation under the scheduler. An operation the task does not handle itself
goes to the scheduler (Async, Channel), then to the root grants; a handler
outside the task never handles it. The checker therefore refuses a task whose
row keeps any other effect (E0837), and accepts handling inside the task.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cat > one.jac <<'EOF'
  > once effect One where {
  >   first : (Int) -> Int
  > }
  > all(thunk) = handle thunk() {
  > | return v -> v
  > | first(n) resume k -> k(add(n, 1))
  > }
  > EOF

The original report: an outer handler around the scope appeared to discharge the
spawned child's effect, so the program checked as pure and the child failed at
run time.

  $ cat one.jac - > outer.jac <<'EOF'
  > t : () ->{} TaskResult (TaskResult Int)
  > t() = all(fn () -> async.scope(fn () -> {
  >     let c = async.spawn(fn () -> first(1))
  >     async.await(c)
  >   }))
  > t()
  > EOF
  $ jacquard check outer.jac
  outer.jac:10:13-43: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

A handler inside the scope body but around the spawn is still outside the child.

  $ cat one.jac - > around-spawn.jac <<'EOF'
  > t() = async.scope(fn () -> all(fn () -> {
  >     let c = async.spawn(fn () -> first(1))
  >     async.await(c)
  >   }))
  > t()
  > EOF
  $ jacquard check around-spawn.jac
  around-spawn.jac:9:13-43: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

A scope body is a task too: performing the effect directly in it under an outer
handler is refused.

  $ cat one.jac - > scope-body.jac <<'EOF'
  > t() = all(fn () -> async.scope(fn () -> first(1)))
  > t()
  > EOF
  $ jacquard check scope-body.jac
  scope-body.jac:8:20-50: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

A nested scope inside a child, with the handler between the child and the
nested scope, still leaves the nested body unhandled.

  $ cat one.jac - > nested.jac <<'EOF'
  > t() = async.scope(fn () -> {
  >     let c = async.spawn(fn () -> all(fn () -> async.scope(fn () -> first(1))))
  >     async.await(c)
  >   })
  > t()
  > EOF
  $ jacquard check nested.jac
  nested.jac:9:47-77: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

The rule covers built-in effects that are not root-grantable, such as State
under an outer state.run.

  $ cat > state.jac <<'EOF'
  > t() = state.run(fn () -> async.scope(fn () -> {
  >     let c = async.spawn(fn () -> put(1))
  >     async.await(c)
  >   }), 0)
  > t()
  > EOF
  $ jacquard check state.jac
  state.jac:2:13-41: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `state`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

The flag travels through a polymorphic helper's inferred signature.

  $ cat one.jac - > helper.jac <<'EOF'
  > helper(thunk) = async.spawn(thunk)
  > t() = all(fn () -> async.scope(fn () -> {
  >     let c = helper(fn () -> first(1))
  >     async.await(c)
  >   }))
  > t()
  > EOF
  $ jacquard check helper.jac
  helper.jac:10:13-38: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

A task row and the row of the spawn or scope call that starts it are distinct:
the task's own effects flow outward into the call's row, but nothing outside the
task flows in. A callback the parent runs before opening a scope (formerly
refused, the same shape as scoped-instance Limit L2) therefore checks and runs.

  $ cat one.jac - > callback.jac <<'EOF'
  > h(g) = {
  >   let x = g()
  >   async.scope(fn () -> x)
  > }
  > t() = all(fn () -> h(fn () -> first(1)))
  > t()
  > EOF
  $ jacquard run callback.jac
  done(2)

An outer handler, a built-in handler or a wider annotation around code that
merely opens a scope does not reach the scope body, whichever comes first.

  $ cat one.jac - > around-scope.jac <<'EOF'
  > direct-before() = handle {
  >   let x = first(1)
  >   let r = async.scope(fn () -> 1)
  >   (x, r)
  > } {
  > | return v -> v
  > | first(n) resume k -> k(add(n, 1))
  > }
  > direct-after() = handle {
  >   let r = async.scope(fn () -> 1)
  >   (r, first(1))
  > } {
  > | return v -> v
  > | first(n) resume k -> k(add(n, 1))
  > }
  > thunk() = all(fn () -> async.scope(fn () -> 1))
  > stateful() = state.run(fn () -> async.scope(fn () -> 1), 0)
  > run2(f) = all(f)
  > relayed() = run2(fn () -> async.scope(fn () -> 1))
  > wide : () ->{One} TaskResult Int
  > wide() = async.scope(fn () -> 1)
  > (direct-before(), direct-after(), thunk(), stateful(), relayed(), all(wide))
  > EOF
  $ jacquard run around-scope.jac
  ((2, done(1)), (done(1), 2), done(1), (done(1), 0), done(1), done(1))

Joining a spawning or scope-opening function with one that performs a handled
user effect (by `if` or a shared parameter) constrains only the call's row.

  $ cat one.jac - > joins.jac <<'EOF'
  > both(f, g) = (f(), g())
  > outside() = all(fn () -> both(fn () -> async.scope(fn () -> 1), fn () -> done(first(1))))
  > branch(b) = async.scope(fn () -> all(fn () -> {
  >   let f = if b then fn () -> {
  >     let c = async.spawn(fn () -> 1)
  >     async.await(c)
  >   } else fn () -> done(first(1))
  >   f()
  > }))
  > paired() = async.scope(fn () -> all(fn () -> both(fn () -> {
  >     let c = async.spawn(fn () -> 1)
  >     async.await(c)
  >   }, fn () -> done(first(1)))))
  > (outside(), branch(true), branch(false), paired())
  > EOF
  $ jacquard run joins.jac
  ((done(1), done(2)), done(done(1)), done(done(2)), done((done(1), done(2))))

A Warp Case's closed Check row around a scope whose body performs no Check
operation is accepted as well.

  $ cat > case-row.jac <<'EOF'
  > scoped-case =
  >   Case("opens a scope", fn () -> {
  >     let r = async.scope(fn () -> 1)
  >     ()
  >   })
  > EOF
  $ jacquard check case-row.jac
  ok

The effects a task does perform still reach the call's row, so a granted effect
in a child stays visible to `--allow` and manifest checking.

  $ cat > granted-out.jac <<'EOF'
  > t() = async.scope(fn () -> {
  >     let c = async.spawn(fn () -> print("child\n"))
  >     async.await(c)
  >   })
  > t()
  > EOF
  $ jacquard check granted-out.jac --manifest dist
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `print`).
    Next step: grant it with --allow console, or handle the effect in the program
  [1]
  $ jacquard run granted-out.jac
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `t`).
    Next step: grant it with --allow console, or handle the effect in the program
  [3]
  $ jacquard run granted-out.jac --allow console
  child
  done(done(()))

A helper that spawns a caller's thunk inside a scope or inside another task
keeps the link from the thunk to its own call row, so a granted effect in the
thunk reaches the caller.

  $ cat > nested-helpers.jac <<'EOF'
  > go(g) = async.scope(fn () -> {
  >     let c = async.spawn(g)
  >     async.await(c)
  >   })
  > sp(g) = async.spawn(fn () -> {
  >     let c = async.spawn(g)
  >     async.await(c)
  >   })
  > t() = (go(fn () -> print("go\n")), async.scope(fn () -> async.await(sp(fn () -> print("sp\n")))))
  > t()
  > EOF
  $ jacquard check nested-helpers.jac --manifest dist
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `print`).
    Next step: grant it with --allow console, or handle the effect in the program
  [1]
  $ jacquard run nested-helpers.jac --allow console
  go
  sp
  (done(done(())), done(done(done(()))))

Known limit: the checker has no subeffecting, so one thunk's row is one row.
A thunk the parent both calls and spawns shares its row with the task, and an
annotation that names one row variable for both the task row and the call row
merges them. A handler around either is then refused, although no task performs
the effect. Give such a helper two row variables, as the inferred signatures do.

  $ cat one.jac - > both-ways.jac <<'EOF'
  > both-ways(t) = { let x = t(); let c = async.spawn(t); (x, async.await(c)) }
  > u() = async.scope(fn () -> all(fn () -> both-ways(fn () -> 1)))
  > EOF
  $ jacquard check both-ways.jac
  both-ways.jac:9:28-63: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]
  $ cat one.jac - > one-var.jac <<'EOF'
  > sc : forall a | e. (() ->{Async | e} a) ->{| e} TaskResult a
  > sc(b) = async.scope(b)
  > t() = all(fn () -> sc(fn () -> 1))
  > EOF
  $ jacquard check one-var.jac
  one-var.jac:10:7-35: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]
  $ cat one.jac - > two-vars.jac <<'EOF'
  > sc : forall a | e e1. (() ->{Async | e1} a) ->{| e} TaskResult a
  > sc(b) = async.scope(b)
  > t() = all(fn () -> sc(fn () -> 1))
  > bad() = all(fn () -> sc(fn () -> first(1)))
  > EOF
  $ jacquard check two-vars.jac
  two-vars.jac:11:22-43: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `one`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

The policy is decided by identity. A user effect spelled like the root-grantable
built-in Clock is still refused in a task, and the diagnostic qualifies its name.

  $ cat > clock.jac <<'EOF'
  > effect Clock where {
  >   once tick : () -> Int
  > }
  > fixed(thunk) = handle thunk() {
  > | return v -> v
  > | tick() resume k -> k(7)
  > }
  > t() = fixed(fn () -> async.scope(fn () -> tick()))
  > t()
  > EOF
  $ jacquard check clock.jac
  clock.jac:8:22-50: error[E0837]: An effect performed in a task is not handled inside the task
    Cause: a task (an async.spawn child or an async.scope body) performs `unpackaged:1f94d485f5a2/clock`, and no handler inside the task handles it; a task runs on a fresh continuation under the scheduler, so a handler outside the task never handles its operations
    Next step: Handle the effect inside the thunk passed to async.spawn or async.scope.
  [1]

Performing the effect directly in the parent, outside the scope, is accepted.

  $ cat one.jac - > parent.jac <<'EOF'
  > t() = all(fn () -> {
  >   let x = first(1)
  >   async.scope(fn () -> x)
  > })
  > t()
  > EOF
  $ jacquard run parent.jac
  done(2)

Handling the effect inside the child is accepted and runs, including in a
grandchild.

  $ cat one.jac - > inside.jac <<'EOF'
  > t() = async.scope(fn () -> {
  >     let c = async.spawn(fn () -> all(fn () -> first(1)))
  >     let d = async.spawn(fn () -> {
  >       let g = async.spawn(fn () -> all(fn () -> first(2)))
  >       async.await(g)
  >     })
  >     (async.await(c), async.await(d))
  >   })
  > t()
  > EOF
  $ jacquard run inside.jac
  done((done(2), done(done(3))))

Root-grantable effects and the scheduler's Channel effect may stay unhandled in
a task: the root grant or the scheduler handles them.

  $ cat > granted.jac <<'EOF'
  > t() = async.scope(fn () -> {
  >     let c = async.spawn(fn () -> print("child\n"))
  >     let d = async.spawn(fn () -> sample(Bernoulli(1.0)))
  >     (async.await(c), async.await(d))
  >   })
  > t()
  > EOF
  $ jacquard run granted.jac --allow console --allow dist --seed 3
  child
  done((done(()), done(true)))
  $ cat > channel.jac <<'EOF'
  > t() = async.scope(fn () -> match channel.open(1) {
  >     | Ok(ch) -> {
  >         let c = async.spawn(fn () -> channel.send(ch, 7))
  >         let v = channel.recv(ch)
  >         Ok((v, async.await(c)))
  >       }
  >     | Err(e) -> Err(e)
  >   })
  > t()
  > EOF
  $ jacquard run channel.jac
  done(ok((ok(7), done(ok(())))))
