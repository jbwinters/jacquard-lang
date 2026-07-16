The capability manifest (W3.6): a program's inferred row is its authority
manifest; running or checking against a grant set enforces it.

  $ export JACQUARD_PRELUDE=../../prelude

The hostile demo: a generated-looking function that reaches for the network
taints every caller's row.

  $ cat > hostile.jqd <<'EOF_JQD'
  > (defterm ((binding fetch-title ()
  >   (lam ((pvar url)) (app (var net.get) (var url))))))
  > (defterm ((binding summarize ()
  >   (lam ((pvar url)) (app (var fetch-title) (var url))))))
  > (app (var summarize) (lit "http://example.com"))
  > EOF_JQD
  $ jacquard check hostile.jqd --print-sigs
  fetch-title : (Text) ->{Net} Text
  summarize : (Text) ->{Net} Text
  _ : Text

Checking against a grant set that lacks net refuses at the type level, naming
the effect and the call-chain endpoint:

  $ jacquard check hostile.jqd --manifest console
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `net.get`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]

With the grant it passes, and the granted run succeeds against the stub
handler:

  $ jacquard check hostile.jqd --manifest net,console
  ok
  $ jacquard run hostile.jqd --allow net
  "<stub response for http://example.com>"

Running without the net grant is the capability refusal (exit 3), even when
some other runtime handler is granted:

  $ jacquard run hostile.jqd --allow console
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `summarize`)
    hint: grant it with --allow net, or handle the effect in the program
  [3]
  $ jacquard run hostile.jqd
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `summarize`)
    hint: grant it with --allow net, or handle the effect in the program
  [3]

Pure effects are never grantable, so the hint must not suggest a --allow flag
that would only bounce with E0703:

  $ cat > pure.jqd <<'JACQUARD'
  > (app (var option.get!) (var none))
  > JACQUARD
  $ jacquard run pure.jqd
  error[E0814]: this program requires abort [control/none] — stop a computation without an error payload, which is not granted (performed via `option.get!`)
    hint: handle the effect in the program (this effect is pure and cannot be granted)
  [3]
  $ jacquard run pure.jqd --allow abort
  error[E0703]: effect `abort` is not grantable
  [1]

SC.4 keeps a spawned child's public effects in the parent row even when
async.spawn travels through a higher-order wrapper. async.scope discharges
only Async, so the documented fetch-all shape needs Net but not Async.

  $ cat > fetch-all.jac <<'JACQUARD'
  > type Task a = | TaskOpaque
  > type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled
  > once effect Async a where {
  >   async.spawn : (() ->{Async | e} a) -> Task a
  >   async.await : (Task a) -> TaskResult a
  >   async.cancel : (Task a) -> ()
  >   async.yield : () -> ()
  > }
  > async.scope(body) =
  >   handle body() {
  >     | return value -> Done(value)
  >     | async.spawn(_) resume continue -> Cancelled
  >     | async.await(_) resume continue -> continue(Cancelled)
  >     | async.cancel(_) resume continue -> continue(())
  >     | async.yield() resume continue -> continue(())
  >   }
  > forward(spawner, child) = spawner(child)
  > fetch-all(urls) =
  >   async.scope(fn () -> {
  >     let tasks = list.map(urls, fn (url) -> forward(async.spawn, fn () -> net.get(url)))
  >     list.map(tasks, fn (task) -> async.await(task))
  >   })
  > fetch-all(Cons("https://example.invalid", Nil))
  > JACQUARD
  $ jacquard check fetch-all.jac --print-sigs
  async.scope : forall a | e. (() ->{Async | e} a) ->{| e} TaskResult a
  forward : forall a b | e. ((b) ->{| e} a, b) ->{| e} a
  fetch-all : (List Text) ->{Net} TaskResult (List (TaskResult Text))
  _ : TaskResult (List (TaskResult Text))
  $ jacquard check fetch-all.jac --manifest console
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `net.get`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]
  $ jacquard check fetch-all.jac --manifest net
  ok

A misleading closed annotation cannot launder the child row through an alias;
the equation diagnostic retains the propagated Net effect.

  $ cat > alias-launder.jac <<'JACQUARD'
  > type Task a = | TaskOpaque
  > type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled
  > once effect Async a where {
  >   async.spawn : (() ->{Async | e} a) -> Task a
  >   async.await : (Task a) -> TaskResult a
  >   async.cancel : (Task a) -> ()
  >   async.yield : () -> ()
  > }
  > spawn-alias = async.spawn
  > launder : () ->{Async} Task Text
  > launder() = spawn-alias(fn () -> net.get("https://example.invalid"))
  > JACQUARD
  $ jacquard check alias-launder.jac
  alias-launder.jac:11:1-69: error[E0804]: equation definition `launder` does not match its signature: expected () ->{async} task text, got () ->{async, net | e} task text (a closed effect row cannot absorb extra effects; a stored definition passed as a thunk can be eta-expanded at the use site: (lam () (app (var f))))
  [1]

Adversarial polymorphic rows also fail at the async.spawn source instead of
solving a cyclic child/caller row.

  $ cat > row-cycle.jac <<'JACQUARD'
  > type Task a = | TaskOpaque
  > type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled
  > once effect Async a where {
  >   async.spawn : (() ->{Async | e} a) -> Task a
  >   async.await : (Task a) -> TaskResult a
  >   async.cancel : (Task a) -> ()
  >   async.yield : () -> ()
  > }
  > force-cycle : forall a | e. ((() ->{| e} a) ->{Net | e} Task a) ->{} Int
  > force-cycle(_) = 0
  > cycle() = force-cycle(async.spawn)
  > JACQUARD
  $ jacquard check row-cycle.jac
  row-cycle.jac:11:23-34: error[E0801]: argument: expected (() ->{async | e} a) ->{async, net | e} task a, got (() ->{async | e} a) ->{async | e} task a (occurs check: effect rows with the same tail differ)
    hint: the expected side comes from the surrounding context; make both sides agree
  [1]

A user effect that reuses an official short name does not inherit its risk or grant:

  $ cat > spoof.jqd <<'JACQUARD'
  > (defeffect net () (op package.fetch once () (tref text)))
  > (app (var package.fetch))
  > JACQUARD
  $ jacquard check spoof.jqd --manifest console
  error[E0814]: this program requires unpackaged:a46cb801752d/net [unrated user effect #a46cb801752d15e51f6c46c91d0c4fa874b337d7186f8b3003230442baad74f1], which is not granted (performed via `package.fetch`)
    hint: handle the effect in the program (unregistered user effects have no built-in --allow grant)
  [1]
