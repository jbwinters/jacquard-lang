-- Illustrative net enjoyment points, not measured weather or preference data.
type PicnicWeather = | Sunny | Cloudy | Rainy

type PicnicAttendance = | SmallGroup | LargeGroup

type PicnicWorld = | PicnicWorld(weather: PicnicWeather, attendance: PicnicAttendance)

type PicnicVenue = | Park | Pavilion | Indoors

type PicnicForecast = | DryForecast | WetForecast

picnic.real(n) = match text.to-real(text.from-int(n)) {
                   | Some(value) -> value
                   | None -> 0.0}

picnic.rate(percent) = real.div(picnic.real(percent), 100.0)

picnic.valid?(
  rain,
  accuracy,
  cost,
) =
  bool.and(
    bool.and(int.gte?(rain, 0), int.lte?(rain, 100)),
    bool.and(
      bool.and(int.gte?(accuracy, 50), int.lte?(accuracy, 100)),
      bool.and(int.gte?(cost, 0), int.lte?(cost, 100)),
    ),
  )

-- Weather is sampled once. Attendance depends on that same weather.
-- On dry days: 70% sunny, 30% cloudy. Large-group probabilities are
-- 80% in sun, 60% under clouds, and 25% in rain.
picnic.world(
  rain,
) =
  {
    let wet = picnic.rate(rain)
    let dry = real.sub(1.0, wet)
    let weather =
      sample(
        Categorical(
          [
            MkPair(Sunny, real.mul(dry, 0.7)),
            MkPair(Cloudy, real.mul(dry, 0.3)),
            MkPair(Rainy, wet),
          ],
        ),
      )
    let large-probability = match weather {
                              | Sunny -> 0.8
                              | Cloudy -> 0.6
                              | Rainy -> 0.25}
    let large = sample(Bernoulli(large-probability))
    PicnicWorld(weather, if large then LargeGroup else SmallGroup)
  }

picnic.prior(rain) = dist.enumerate(fn () -> picnic.world(rain))

picnic.utility(
  venue,
  world,
) =
  match (venue, world) {
    | (Park, PicnicWorld(Sunny, SmallGroup)) -> 80.0
    | (Park, PicnicWorld(Sunny, LargeGroup)) -> 100.0
    | (Park, PicnicWorld(Cloudy, SmallGroup)) -> 55.0
    | (Park, PicnicWorld(Cloudy, LargeGroup)) -> 70.0
    | (Park, PicnicWorld(Rainy, SmallGroup)) -> -25.0
    | (Park, PicnicWorld(Rainy, LargeGroup)) -> -40.0
    | (Pavilion, PicnicWorld(Rainy, SmallGroup)) -> 35.0
    | (Pavilion, PicnicWorld(Rainy, LargeGroup)) -> 45.0
    | (Pavilion, PicnicWorld(_, SmallGroup)) -> 65.0
    | (Pavilion, PicnicWorld(_, LargeGroup)) -> 80.0
    | (Indoors, PicnicWorld(Rainy, SmallGroup)) -> 55.0
    | (Indoors, PicnicWorld(Rainy, LargeGroup)) -> 65.0
    | (Indoors, PicnicWorld(_, SmallGroup)) -> 45.0
    | (Indoors, PicnicWorld(_, LargeGroup)) -> 55.0
  }

picnic.mean(
  table,
  value,
) =
  list.fold(
    table,
    0.0,
    fn (
      total,
      entry,
    ) ->
      match entry {
        | MkPair(world, probability) -> real.add(total, real.mul(probability, value(world)))
      },
  )

picnic.mass(table) = picnic.mean(table, fn (_) -> 1.0)

picnic.expected(venue, table) = picnic.mean(table, fn (world) -> picnic.utility(venue, world))

picnic.downside(
  venue,
  table,
) =
  picnic.mean(table, fn (world) -> if real.lt?(picnic.utility(venue, world), 0.0) then 1.0 else 0.0)

-- Stable tie order: park, then pavilion, then indoors.
picnic.best(
  table,
) =
  list.fold(
    [Pavilion, Indoors],
    Park,
    fn (
      best,
      candidate,
    ) ->
      if real.gt?(picnic.expected(candidate, table), picnic.expected(best, table)) then candidate
      else best,
  )

picnic.dry-likelihood(
  world,
  accuracy,
) =
  match world {
    | PicnicWorld(Rainy, _) -> real.sub(1.0, picnic.rate(accuracy))
    | _ -> picnic.rate(accuracy)
  }

picnic.signal-likelihood(
  world,
  accuracy,
  signal,
) =
  {
    let dry = picnic.dry-likelihood(world, accuracy)
    match signal {
      | DryForecast -> dry
      | WetForecast -> real.sub(1.0, dry)
    }
  }

picnic.signal-mass(
  rain,
  accuracy,
  signal,
) =
  picnic.mean(picnic.prior(rain), fn (world) -> picnic.signal-likelihood(world, accuracy, signal))

picnic.posterior(
  rain,
  accuracy,
  signal,
) =
  -- Do not normalize an impossible event: the all-zero Dist library case is
  -- explicitly excluded before entering the inference handler.
  if real.lte?(picnic.signal-mass(rain, accuracy, signal), 0.0) then None
  else Some(
         dist.enumerate(
           fn () ->
             {
               let world = picnic.world(rain)
               observe(Bernoulli(picnic.signal-likelihood(world, accuracy, signal)), True)
               world
             },
         ),
       )

picnic.informed-value(
  rain,
  accuracy,
) =
  list.fold(
    [DryForecast, WetForecast],
    0.0,
    fn (
      total,
      signal,
    ) ->
      match picnic.posterior(rain, accuracy, signal) {
        | None -> total
        | Some(table) ->
          real.add(
            total,
            real.mul(
              picnic.signal-mass(rain, accuracy, signal),
              picnic.expected(picnic.best(table), table),
            ),
          )
      },
  )

picnic.information-value(
  rain,
  accuracy,
) =
  {
    let prior = picnic.prior(rain)
    real.sub(picnic.informed-value(rain, accuracy), picnic.expected(picnic.best(prior), prior))
  }

picnic.buy?(
  rain,
  accuracy,
  cost,
) =
  -- Numerical ties within one billionth of a point prefer no purchase.
  real.gt?(picnic.information-value(rain, accuracy), real.add(picnic.real(cost), 1e-09))

picnic.venue-name(
  venue,
) =
  match venue {
    | Park -> "park"
    | Pavilion -> "covered pavilion"
    | Indoors -> "indoors"
  }

picnic.signal-name(
  signal,
) =
  match signal {
    | DryForecast -> "dry forecast"
    | WetForecast -> "wet forecast"
  }

picnic.advice(
  rain,
  accuracy,
  cost,
) =
  if picnic.valid?(rain, accuracy, cost) then
    Ok((picnic.best(picnic.prior(rain)), picnic.buy?(rain, accuracy, cost)))
  else Err("Use rain 0..100%, forecast accuracy 50..100%, and cost 0..100 enjoyment points.")

picnic.show(
  rain,
  accuracy,
  cost,
) =
  match picnic.advice(rain, accuracy, cost) {
    | Err(message) -> println(message)
    | Ok((venue, buy)) -> {
      let prior = picnic.prior(rain)
      println(
        $"Rain chance {text.from-int(rain)}%; forecast accuracy {text.from-int(accuracy)}%; forecast cost {text.from-int(cost)} points",
      )
      list.each(
        [Park, Pavilion, Indoors],
        fn (
          candidate,
        ) ->
          println(
            $"  {picnic.venue-name(candidate)}: expected enjoyment = {display.fixed3(picnic.expected(candidate, prior))}; chance of negative enjoyment = {display.percent(picnic.downside(candidate, prior))}",
          ),
      )
      println($"Without more information: choose {picnic.venue-name(venue)}.")
      list.each(
        [DryForecast, WetForecast],
        fn (
          signal,
        ) ->
          match picnic.posterior(rain, accuracy, signal) {
            | None ->
              println($"  {picnic.signal-name(signal)}: impossible under these assumptions.")
            | Some(table) ->
              println(
                $"  {picnic.signal-name(signal)}: probability {display.percent(picnic.signal-mass(rain, accuracy, signal))}; choose {picnic.venue-name(picnic.best(table))}.",
              )
          },
      )
      println(
        $"Forecast information is worth {display.fixed3(picnic.information-value(rain, accuracy))} enjoyment points before its cost.",
      )
      println(
        if buy then "Recommendation: buy the forecast, then choose the indicated venue."
        else "Recommendation: skip the forecast and choose the venue above.",
      )
    }
  }

picnic.demo() =
  {
    println("PICNIC DECISION PLANNER")
    println("Synthetic scenarios, net enjoyment points, expected-enjoyment objective.")
    println("Attendance depends on the same weather used to score every venue.")
    println("All finite paths are enumerated; displayed values are rounded to three decimals.")
    picnic.show(30, 80, 1)
    println("\nSensitivity: almost dry, then very wet, then an uninformative forecast.")
    picnic.show(5, 80, 1)
    picnic.show(90, 80, 1)
    picnic.show(30, 50, 0)
  }

picnic.interactive() =
  {
    println("PICNIC DECISION PLANNER: illustrative enjoyment model")
    let rain-text = console.ask("Chance of rain, whole percent (0..100)?")
    let accuracy-text = console.ask("Forecast accuracy for both wet and dry days (50..100)?")
    let cost-text = console.ask("Forecast cost in whole enjoyment points (0..100)?")
    let parsed-inputs =
      (
        text.to-int(text.trim(rain-text)),
        text.to-int(text.trim(accuracy-text)),
        text.to-int(text.trim(cost-text)),
      )
    match parsed-inputs {
      | (Some(rain), Some(accuracy), Some(cost)) -> picnic.show(rain, accuracy, cost)
      | _ -> println("Please enter whole numbers. Run again to try another scenario.")
    }
  }
