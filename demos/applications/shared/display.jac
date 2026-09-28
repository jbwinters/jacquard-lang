-- Shared presentation only. Models keep full floating-point precision.
-- Bounded fixed-point formatting for these small examples; values outside
-- [-1000, 1000] retain Jacquard's ordinary Real rendering. This rounds half up
-- on the scaled float, as the published transcripts print. text.from-real-fixed
-- rounds the exact binary value instead (80.6425 is 80.642 there, 80.643 here),
-- so the applications keep this formatter to leave their transcripts unchanged.
display.floor-between(
  value,
  lower-bound,
  upper-bound,
) =
  if int.lte?(sub(upper-bound, lower-bound), 1) then lower-bound
  else {
         let middle = div(add(lower-bound, upper-bound), 2)
         if real.lt?(value, real.from-int(middle)) then
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
         $"{sign}{text.from-int(div(scaled, 1000))}.{padded}"
  }

display.percent(probability) = $"{display.fixed3(real.mul(probability, 100.0))}%"
