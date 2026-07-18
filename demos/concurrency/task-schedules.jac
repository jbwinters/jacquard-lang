spawn-net() = async.spawn(fn () -> net.get("https://example.invalid"))

scoped-net() =
  async.scope(fn () -> {
    let child = async.spawn(fn () -> net.get("https://example.invalid"))
    async.await(child)
  })

{
  let _ = async.spawn(fn () -> 1)
  let _ = async.spawn(fn () -> 2)
  0
}
