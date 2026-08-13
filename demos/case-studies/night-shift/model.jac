-- NIGHT-SHIFT: an unattended maintenance bot widens a service fleet's worker
-- pool during a low-traffic window. The run is a chain of custody: exact
-- enumeration forecasts the risk, concurrent probe tasks preflight the fleet
-- inside a simulated world, a scripted approver consents to the exact
-- migration code hash, the deploy token stays redacted end to end, and the
-- final lever is a once-mode operation that fires the quoted migration only
-- through the granted `eval` capability. Net, Clock, State, Dist, Async, and
-- Approval are all discharged in-language; what remains in the signatures is
-- either grantable authority (Eval, Secret) or ungrantable plumbing the
-- interpreter's deterministic scheduler routes (Channel).
--
-- Steps the transcript proves:
--   1. `jacquard check --print-sigs`: probe.run comes out PURE because each
--      task carries its own simulated world, and ship.live visibly trades the
--      once-mode Ship effect for Eval. Grantable authority: Eval and Secret.
--   2. Ungranted `run`: the authority-free forecast still completes, then the
--      decision step refuses with E0814 at exit 3. Nothing ships.
--   3. Granted `run` completes the whole shift; the token prints redacted and
--      the transcript provably never contains its plaintext.
--   4. Warp cases pin the deterministic schedule; --exhaustive proves the
--      preflight and window claims over all 27 fleet worlds.

-- --- the domain ---

--| a service's condition in one possible world
type Mood = | Ready | Lagging | Wedged

--| the three services the night shift must not break
type Fleet = | MkFleet(api: Mood, db: Mood, cache: Mood)

--| one probe task's verdict: which service, healthy?, simulated ms spent
type Reading = | MkReading(name: Text, ok: Bool, ms: Int)

-- --- the simulated world: each probe task carries its own weather ---

mood.latency(m) = match m {
  | Ready -> 40
  | Lagging -> 700
  | Wedged -> 90
}

mood.answer(m) = match m {
  | Ready -> MkResponse(200, "ok")
  | Lagging -> MkResponse(200, "ok")
  | Wedged -> MkResponse(503, "unavailable")
}

fleet.mood-of(f, name) = match f {
  | MkFleet(a, d, c) ->
      if text.eq?(name, "api") then a
      else if text.eq?(name, "db") then d
      else c
}

--| a deep handler that answers `fetch` from one service's mood and charges a
--| simulated clock: `now` reads elapsed ms from a State cell, `sleep` charges
--| time instead of waiting. Effects are routed per task, so each probe task
--| installs this lab around its own body -- three private worlds, one fleet.
lab : (Mood, () ->{State, Net, Clock | e} a) ->{State | e} a
lab(m, thunk) =
  handle thunk() {
    | return x -> x
    | fetch(req) resume k -> {
        let t = get()
        put(add(t, mood.latency(m)))
        k(mood.answer(m))
      }
    | now() resume k -> k(get())
    | sleep(d) resume k -> {
        put(add(get(), d))
        k(())
      }
  }

resp.ok?(r) = match r {
  | MkResponse(st, _) -> eq(st, 200)
}

--| one probe: fetch the health endpoint, retry once after a beat if it looks
--| bad, and report what the simulated clock charged. Ordinary {Net, Clock}
--| code -- it cannot tell the lab from production.
probe.check : (Text) ->{Net, Clock} (Bool, Int)
probe.check(name) = {
  let t0 = now()
  let first = fetch(MkRequest(text.concat("http://", name), ""))
  let healthy =
    if resp.ok?(first) then True
    else {
      sleep(120)
      resp.ok?(fetch(MkRequest(text.concat("http://", name), "")))
    }
  (healthy, sub(now(), t0))
}

--| run one probe as a pure value: the lab discharges Net/Clock, state.run
--| discharges State, so a spawned probe task has the empty row.
probe.run(f, name) =
  match state.run(fn () -> lab(fleet.mood-of(f, name), fn () -> probe.check(name)), 0) {
    | ((healthy, _), ms) -> MkReading(name, healthy, ms)
  }

--| the sequential twin of the preflight: the same three probes, no
--| scheduler. The Warp suite and the forecast use this hermetic form; the
--| live shift runs the concurrent channel form below, and the transcript
--| shows both produce identical readings.
preflight.solo(f) =
  [probe.run(f, "api"), probe.run(f, "db"), probe.run(f, "cache")]

-- --- concurrent preflight: three probe tasks, one typed channel ---

drain(ch) = match channel.recv(ch) {
  | Ok(v) -> Cons(v, drain(ch))
  | Err(_) -> Nil
}

--| spawn one task per service; each sends its Reading into a bounded channel;
--| the coordinator awaits the senders, closes, and drains. Under the default
--| deterministic round-robin scheduler the drained order is pinned -- the
--| granted lane of the run.sh transcript shows it, byte for byte.
preflight(f) = {
  let outcome = async.scope(fn () ->
    match channel.open(3) {
      | Err(_) -> Nil
      | Ok(ch) -> {
          let p-api = async.spawn(fn () -> channel.send(ch, probe.run(f, "api")))
          let p-db = async.spawn(fn () -> channel.send(ch, probe.run(f, "db")))
          let p-cache = async.spawn(fn () -> channel.send(ch, probe.run(f, "cache")))
          let _ = async.await(p-api)
          let _ = async.await(p-db)
          let _ = async.await(p-cache)
          let _ = channel.close(ch)
          drain(ch)
        }
    })
  match outcome {
    | Done(readings) -> readings
    | _ -> Nil
  }
}

reading.ok?(r) = match r { | MkReading(_, healthy, _) -> healthy }
reading.ms(r) = match r { | MkReading(_, _, ms) -> ms }

--| green means every service answered and the whole preflight fit the budget
preflight.green?(readings) = {
  let all-ok = list.fold(readings, True, fn (acc, r) -> bool.and(acc, reading.ok?(r)))
  let total = list.fold(readings, 0, fn (acc, r) -> add(acc, reading.ms(r)))
  bool.and(all-ok, bool.and(eq(list.length(readings), 3), int.lt?(total, 2500)))
}

-- --- the watchdog: a cancelled task is a first-class, expected outcome ---

stand-watch() = {
  let _ = async.yield()
  stand-watch()
}

--| the watchdog yields forever, ready to page a human; a quiet preflight
--| cancels it. Under the fail-fast policy the cancelled child becomes the
--| scope's own result, so `Cancelled` here MEANS "nobody was paged".
watch.report() = {
  let shift = async.scope(fn () -> {
    let watchdog = async.spawn(fn () -> stand-watch())
    let _ = async.cancel(watchdog)
    async.await(watchdog)
  })
  match shift {
    | Cancelled -> "watchdog stood down; no page sent"
    | _ -> "watchdog escaped its shift"
  }
}

-- --- the migration: quoted code, hash-bound consent, a once-mode lever ---

--| the migration is DATA until the lever fires: a quoted expression that
--| computes the widened pool size. Quoting costs nothing and needs no grant.
migration = quote { mul(8, 2) }

must-hash(text) = match hash.parse(text) {
  | Ok(value) -> value
  | Err(message) -> throw(message)
}

--| consent is bound to content: the proposal carries the exact migration
--| Code and asks for the Eval authority by name.
night-proposal() = approval.make-proposal(
  must-hash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
  must-hash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
  must-hash("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
  [Effect("Eval")],
  migration,
  "widen worker pool during tonight's window?",
  None)

--| the final lever. `once` is load-bearing: the checker rejects any handler
--| that could resume this operation twice, so the migration cannot be
--| double-applied by construction.
once effect Ship where {
  apply : (Code) -> Int
}

--| fire the lever through the granted `eval` capability -- exactly once
ship.live(thunk) =
  handle thunk() {
    | return x -> x
    | apply(code) resume k -> k(`op:eval-code`(code))
  }

--| the shift's decision spine: a green preflight earns a scripted approval
--| bound to this proposal's id; anything else escalates and ships nothing.
decide(readings) = {
  let p = night-proposal()
  let id = approval.proposal-id(p)
  if preflight.green?(readings) then
    match approval.scripted(fn () -> `op:ask`(p), [Approved(id, "night-shift-bot", quote { ticket("NS-1") })]) {
      | Approved(_, actor, _) ->
          ship.live(fn () ->
            (text.concat("shipped by ", actor), `op:apply`(migration)))
      | _ -> ("approver refused; pool unchanged", 8)
    }
  else
    match approval.policy-auto(fn () -> `op:ask`(p), fn (ignored) -> Ask) {
      | _ -> ("escalated to a human; pool unchanged", 8)
    }
}

-- --- the forecast: exact risk, and a multi-shot A/B of two rollout plans ---

sky(p-ready, p-lagging, p-wedged) =
  Categorical([
    MkPair(Ready, p-ready),
    MkPair(Lagging, p-lagging),
    MkPair(Wedged, p-wedged)])

forecast : () ->{Dist} Fleet
forecast() = {
  let a = sample(sky(0.90, 0.08, 0.02))
  let d = sample(sky(0.94, 0.04, 0.02))
  let c = sample(sky(0.80, 0.15, 0.05))
  MkFleet(a, d, c)
}

--| would tonight's preflight come back green in this world? The forecast
--| projects each world through the sequential twin so enumeration stays
--| hermetic -- same probes, same readings, no schedule dependence.
world.green?(f) = preflight.green?(preflight.solo(f))

--| a multi-shot choice: ONE pass explores BOTH rollout plans. The handler
--| resumes the continuation twice -- the m1-choose move doing real work.
multi effect Rollout where {
  pick : () -> Bool
}

plan.label(big-bang) = if big-bang then "big-bang" else "rolling"

--| big-bang pays every wedged service at once; rolling pays a fixed per-step
--| overhead but never more than the worst single service.
plan.window(big-bang, f) = match f {
  | MkFleet(a, d, c) -> {
      let worst = list.fold([a, d, c], 0, fn (acc, m) ->
        if int.lt?(acc, mood.latency(m)) then mood.latency(m) else acc)
      let total = list.fold([a, d, c], 0, fn (acc, m) -> add(acc, mood.latency(m)))
      if big-bang then total else add(worst, 180)
    }
}

both-plans(f) =
  handle {
    let big-bang = `op:pick`()
    Cons((plan.label(big-bang), plan.window(big-bang, f)), Nil)
  } {
    | return x -> x
    | pick() resume k -> list.append(k(True), k(False))
  }

--| P(a green preflight) -- exact, over all 27 worlds, weighted by the sky
risk.green() =
  dist.enumerate(fn () -> if world.green?(forecast()) then "green" else "red")
  |> dist.tally(text.eq)

--| the counterfactual: given the window overran, which plan was running?
--| `observe` conditions the enumeration; nothing is sampled approximately.
risk.overrun-blame() =
  dist.enumerate(fn () -> {
    let f = forecast()
    let windows = both-plans(f)
    let overran = list.filter(windows, fn (entry) ->
      match entry { | (_, w) -> int.lt?(900, w) })
    observe(Bernoulli(if int.lt?(0, list.length(overran)) then 1.0 else 0.0), True)
    list.map(overran, fn (entry) -> match entry { | (label, _) -> label })
      |> list.fold("", fn (acc, label) ->
           if text.empty?(acc) then label else text.concat(acc, text.concat("+", label)))
  })
  |> dist.tally(text.eq)
  |> list.filter(fn (entry) -> match entry { | MkPair(_, mass) -> real.lt?(0.0, mass) })

-- --- the deploy token: readable by the program, redacted in every transcript ---

--| `secret.read` needs the root `secret` grant; the value it returns renders
--| as <secret redacted> everywhere. `secret.expose` yields the plaintext to
--| the program -- here only to check its shape, which exposes one boolean.
token.report() = {
  let token = secret.read(secret-ref("night-shift-token", None))
  (token, text.contains?(secret.expose(token), "nsk-"))
}

-- --- demo driver ---

risk.green()
risk.overrun-blame()

throw.to-result(fn () -> {
  let readings = preflight(MkFleet(Ready, Ready, Ready))
  (readings, decide(readings))
})

watch.report()
token.report()
