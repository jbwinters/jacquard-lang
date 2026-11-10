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

Known limit (the same as scoped-instance Limit L2): a body's ambient row shares
the scope's row tail, so a callback the body runs in the parent is restricted
too. This program would run correctly, but the checker refuses it.

  $ cat one.jac - > limit.jac <<'EOF'
  > h(g) = {
  >   let x = g()
  >   async.scope(fn () -> x)
  > }
  > t() = all(fn () -> h(fn () -> first(1)))
  > t()
  > EOF
  $ jacquard check limit.jac > limit.out 2>&1; echo "exit $?"
  exit 1
  $ head -1 limit.out
  limit.jac:12:20-40: error[E0837]: An effect performed in a task is not handled inside the task

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
