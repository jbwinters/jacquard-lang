type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled

once effect Async a where {
  async.spawn : (() ->{Async | e} a) -> Task a
  async.await : (Task a) -> TaskResult a
  async.cancel : (Task a) -> ()
  async.yield : () -> ()
}

async.scope(body) =
  handle body() {
    | return value -> Done(value)
    | async.spawn(_) resume continue -> Cancelled
    | async.await(_) resume continue -> continue(Cancelled)
    | async.cancel(_) resume continue -> continue(())
    | async.yield() resume continue -> continue(())
  }

spawn-net() = async.spawn(fn () -> net.get("https://example.invalid"))

spawn-alias = async.spawn

alias-net() = spawn-alias(fn () -> net.get("https://example.invalid"))

forward(spawner, child) = spawner(child)

wrapped-net() = forward(async.spawn, fn () -> net.get("https://example.invalid"))

make-spawner() = fn (child) -> async.spawn(child)

returned-net() = make-spawner()(fn () -> net.get("https://example.invalid"))

spawn-bundle = (async.spawn, 0)

tuple-net() = {
  let (spawner, _) = spawn-bundle
  spawner(fn () -> net.get("https://example.invalid"))
}

wrapped-fs() = forward(async.spawn, fn () -> read("child-effects.txt"))

scoped-net() =
  async.scope(fn () -> {
    let child = async.spawn(fn () -> net.get("https://example.invalid"))
    async.await(child)
  })

nested-scoped-net() =
  async.scope(fn () ->
    async.scope(fn () -> {
      let child = async.spawn(fn () -> net.get("https://example.invalid"))
      async.await(child)
    }))

fetch-all(urls) =
  async.scope(fn () -> {
    let tasks = list.map(urls, fn (url) -> async.spawn(fn () -> net.get(url)))
    list.map(tasks, fn (task) -> async.await(task))
  })
