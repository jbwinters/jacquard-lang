-- Standing public regression net for schedule-sensitive structured concurrency.

two-child-results() =
  async.scope(fn () -> {
    let first = async.spawn(fn () -> { async.yield(); 1 })
    let second = async.spawn(fn () -> { async.yield(); 2 })
    (async.await(first), async.await(second))
  })

fail-fast-result() =
  async.scope(fn () -> {
    let worker = async.spawn(fn () -> { async.yield(); 1 })
    let failing = async.spawn(fn () -> div(1, 0))
    (async.await(worker), async.await(failing))
  })

nested-scope-result() =
  async.scope(fn () -> {
    let child = async.spawn(fn () ->
      async.scope(fn () -> {
        async.yield()
        7
      }))
    async.await(child)
  })

two-child-invariance =
  SameUnder(
    "two-child results retain creation order",
    VarySchedule(32, fn () -> two-child-results()))

fail-fast-invariance =
  SameUnder(
    "fail-fast result is schedule invariant",
    VarySchedule(32, fn () -> fail-fast-result()))

nested-invariance =
  SameUnder(
    "nested scope result survives scheduling",
    VarySchedule(32, fn () -> nested-scope-result()))
