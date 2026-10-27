top-three(xs) =
  xs
  |> list.filter(fn (n) -> int.gt?(n, 0))
  |> list.map(fn (n) -> int.mul(n, n))
  |> list.sort(int.ord)
  |> list.take(3)

top-three([-2, 4, 1, 3])
