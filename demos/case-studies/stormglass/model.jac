-- STORMGLASS: an incident-response war-gamer. The thesis move: the OUTAGE is a
-- handler. A checkout flow written against real effects (Net, Clock) runs
-- unchanged inside simulated weather -- each dependency's health is sampled
-- from a prior, the world handler answers fetch accordingly, a simulated clock
-- charges latency instead of waiting -- and multi-shot enumeration then runs
-- the whole flow through EVERY possible world at once, weighted. The outputs
-- are exact: P(clear), P(choppy), P(blackout) per recovery policy, posterior
-- blame given a bad day, and Warp props PROVED over the entire world space.
-- The manifest is empty: every effect is discharged in-language, so running
-- this needs no grants at all.

-- --- the domain ---

--| a dependency's condition in one possible world
type SvcMood = | Up | Slow | Down

--| the three services checkout leans on
type Fleet = | MkFleet(inv: SvcMood, pay: SvcMood, shp: SvcMood)

--| what the business logic reports
type Purchase = | PurchaseOk | PurchaseDegraded | PurchaseFailed

--| what the CUSTOMER experienced, after latency is judged
type Outcome = | Clear | Choppy | Blackout

-- --- the simulation spine: one State cell (elapsed-ms, fetch-count) ---

sim.charge : (Int) ->{State} ()
sim.charge(ms) = match get() {
  | (t, n) -> put((add(t, ms), n))
}

sim.note-fetch : (Int) ->{State} ()
sim.note-fetch(ms) = match get() {
  | (t, n) -> put((add(t, ms), add(n, 1)))
}

--| the simulated clock: `now` reads elapsed ms, `sleep` charges time instead
--| of waiting -- a retry policy's backoff costs simulated seconds, not real
--| ones. Discharges Clock, and adds State to whatever the body already had.
sim.clock : (() ->{State, Clock | e} a) ->{State | e} a
sim.clock(thunk) =
  handle thunk() {
    | return x -> x
    | now() resume k ->
        match get() {
          | (t, _) -> k(t)
        }
    | sleep(d) resume k -> {
        sim.charge(d)
        k(())
      }
  }

-- --- the weather: how a mood answers the phone ---

mood.latency(m) = match m {
  | Up -> 20
  | Slow -> 900
  | Down -> 30
}

mood.answer(m) = match m {
  | Up -> MkResponse(200, "ok")
  | Slow -> MkResponse(200, "ok")
  | Down -> MkResponse(503, "unavailable")
}

fleet.mood-of(f, url) = match f {
  | MkFleet(i, p, s) ->
      if text.contains?(url, "inventory") then i
      else if text.contains?(url, "payment") then p
      else s
}

--| the world handler: answer Net.fetch from the fleet's moods, charging the
--| simulated clock per call. The policy under it cannot tell it isn't real.
fleet.serve : (Fleet, () ->{State, Net | e} a) ->{State | e} a
fleet.serve(f, thunk) =
  handle thunk() {
    | return x -> x
    | fetch(req) resume k ->
        match req {
          | MkRequest(url, _) -> {
              let m = fleet.mood-of(f, url)
              sim.note-fetch(mood.latency(m))
              k(mood.answer(m))
            }
        }
  }

--| run a {Net, Clock} policy inside one concrete world; the tuple state
--| threads elapsed-ms and fetch-count. Every effect is discharged here, so
--| simulate itself is pure -- the empty row is the whole point.
simulate : (Fleet, () ->{State, Net, Clock | e} Purchase) ->{| e} (Purchase, (Int, Int))
simulate(f, policy) =
  state.run(
    fn () -> sim.clock(fn () -> fleet.serve(f, policy)),
    (0, 0))

-- --- grading: the customer's verdict. SLA is 800 simulated ms ---

grade(p, ms) = match p {
  | PurchaseFailed -> Blackout
  | PurchaseDegraded -> Choppy
  | PurchaseOk -> if int.lt?(800, ms) then Choppy else Clear
}

run-graded : (Fleet, () ->{State, Net, Clock | e} Purchase) ->{| e} Outcome
run-graded(f, policy) = match simulate(f, policy) {
  | (res, (ms, _)) -> grade(res, ms)
}

outcome.text(o) = match o {
  | Clear -> "clear"
  | Choppy -> "choppy"
  | Blackout -> "blackout"
}

-- --- the prior: tomorrow's weather, one categorical per service ---

sky(p-up, p-slow, p-down) =
  Categorical([MkPair(Up, p-up), MkPair(Slow, p-slow), MkPair(Down, p-down)])

forecast : () ->{Dist} Fleet
forecast() = {
  let i = sample(sky(0.90, 0.07, 0.03))
  let p = sample(sky(0.95, 0.03, 0.02))
  let s = sample(sky(0.85, 0.10, 0.05))
  MkFleet(i, p, s)
}

-- --- the policies under trial: both are ordinary {Net, Clock} code ---

fetch-url : (Text) ->{Net} Response
fetch-url(url) = fetch(MkRequest(url, ""))

resp.ok?(r) = match r {
  | MkResponse(st, _) -> eq(st, 200)
}

--| one timed call: (succeeded?, took-over-500ms?) -- the policy READS the
--| simulated clock to notice slowness, the way real code reads a real one
timed-ok? : (Text) ->{Net, Clock} (Bool, Bool)
timed-ok?(url) = {
  let t0 = now()
  let r = fetch-url(url)
  let t1 = now()
  (resp.ok?(r), int.lt?(500, sub(t1, t0)))
}

--| POLICY A, "naive": treat every dependency as mandatory, retry each up to
--| three times with a 250ms pause, give up hard. Never notices slowness.
retry-blindly : (Text, Int) ->{Net, Clock} Bool
retry-blindly(url, left) =
  if resp.ok?(fetch-url(url)) then True
  else if eq(left, 1) then False
  else {
    sleep(250)
    retry-blindly(url, sub(left, 1))
  }

naive-checkout : () ->{Net, Clock} Purchase
naive-checkout() =
  if retry-blindly("http://inventory", 3) then
    if retry-blindly("http://payment", 3) then
      if retry-blindly("http://shipping", 3) then PurchaseOk
      else PurchaseFailed
    else PurchaseFailed
  else PurchaseFailed

--| POLICY B, "resilient": inventory falls back to a cached count, payment is
--| the one hard requirement (two tries), shipping failures queue for later.
inv-step : () ->{Net, Clock} Bool
inv-step() = match timed-ok?("http://inventory") {
  | (ok1, slow1) ->
      if ok1 then slow1
      else {
        sleep(100)
        if resp.ok?(fetch-url("http://inventory")) then False else True
      }
}

pay-twice : () ->{Net, Clock} Bool
pay-twice() =
  if resp.ok?(fetch-url("http://payment")) then True
  else {
    sleep(100)
    resp.ok?(fetch-url("http://payment"))
  }

resilient-checkout : () ->{Net, Clock} Purchase
resilient-checkout() = {
  let inv-deg = inv-step()
  if pay-twice() then {
    let shp-deg = if resp.ok?(fetch-url("http://shipping")) then False else True
    if bool.or(inv-deg, shp-deg) then PurchaseDegraded else PurchaseOk
  }
  else PurchaseFailed
}

-- --- the analyses: enumeration runs a policy in EVERY world at once ---

--| exact customer-outcome posterior for one policy under the forecast
tally-policy : (() ->{State, Dist, Net, Clock | e} Purchase) ->{| e} (List (Pair Text Real))
tally-policy(policy) =
  dist.enumerate(fn () -> outcome.text(run-graded(forecast(), policy)))
  |> dist.tally(text.eq)

--| the counterfactual: same posterior CONDITIONED on payment being hard-down
given-payment-down(policy) =
  dist.enumerate(fn () -> {
    let f = forecast()
    let w = match f {
      | MkFleet(_, Down, _) -> 1.0
      | _ -> 0.0
    }
    observe(Bernoulli(w), True)
    outcome.text(run-graded(f, policy))
  })
  |> dist.tally(text.eq)

--| root-cause inference, run BACKWARD: the customer saw a choppy checkout
--| under the resilient policy -- which service do we now believe misbehaved?
mood.tag(name, m) = match m {
  | Up -> ""
  | Slow -> text.concat(name, " slow ")
  | Down -> text.concat(name, " down ")
}

fleet.blame(f) = match f {
  | MkFleet(i, p, s) -> {
      let t =
        text.concat(
          mood.tag("inventory", i),
          text.concat(mood.tag("payment", p), mood.tag("shipping", s)))
      if text.empty?(t) then "all healthy" else text.trim(t)
    }
}

blame-when-choppy() =
  dist.enumerate(fn () -> {
    let f = forecast()
    let out = run-graded(f, fn () -> resilient-checkout())
    let w = match out {
      | Choppy -> 1.0
      | _ -> 0.0
    }
    observe(Bernoulli(w), True)
    fleet.blame(f)
  })
  |> dist.tally(text.eq)

likely-blame(minimum-mass) =
  list.filter(blame-when-choppy(), fn (entry) ->
    match entry {
      | MkPair(_, probability) -> real.lt?(minimum-mass, probability)
    })

--| total probability mass a tallied table assigns one label
mass-of(table, label) =
  list.fold(table, 0.0, fn (acc, e) ->
    match e {
      | MkPair(x, p) ->
          if eq.fn(text.eq)(x, label) then real.add(acc, p) else acc
    })

-- --- demo driver ---

tally-policy(fn () -> naive-checkout())
tally-policy(fn () -> resilient-checkout())
given-payment-down(fn () -> naive-checkout())
given-payment-down(fn () -> resilient-checkout())
likely-blame(0.02)
