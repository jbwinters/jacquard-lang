-- Shared presentation only. Models keep full floating-point precision.
-- Bounded fixed-point formatting for these small examples; values outside
-- [-1000, 1000] retain Jacquard's ordinary Real rendering.
display.real(n) = match text.to-real(text.from-int(n)) {
                    | Some(value) -> value
                    | None -> 0.0}

display.floor-between(
  value,
  lower-bound,
  upper-bound,
) =
  if int.lte?(sub(upper-bound, lower-bound), 1) then lower-bound
  else {
         let middle = div(add(lower-bound, upper-bound), 2)
         if real.lt?(value, display.real(middle)) then
           display.floor-between(value, lower-bound, middle)
         else display.floor-between(value, middle, upper-bound)
  }

display.fixed3(
  value,
) =
  if real.gt?(real.abs(value), 1000.0) then text.from-real(value)
  else {
         let scaled =
           display.floor-between(real.add(real.mul(real.abs(value), 1000.0), 0.5), 0, 1000001)
         let fraction = mod(scaled, 1000)
         let digits = text.from-int(fraction)
         let padded =
           if int.lt?(fraction, 10) then text.concat("00", digits)
           else if int.lt?(fraction, 100) then text.concat("0", digits)
           else digits
         let sign = if bool.and(real.lt?(value, 0.0), int.gt?(scaled, 0)) then "-" else ""
         text.concat(sign, $"{text.from-int(div(scaled, 1000))}.{padded}")
  }

display.percent(probability) = text.concat(display.fixed3(real.mul(probability, 100.0)), "%")
