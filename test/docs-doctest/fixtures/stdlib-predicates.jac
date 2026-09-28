valid(id, name, limit, points) = bool.all([
  int.between?(id, 0, 99),
  bool.not(text.empty?(name)),
  int.between?(limit, 0, 14),
  list.all?(points, fn (p) -> int.between?(p, 0, 10)),
])
(valid(7, "Ada", 3, [5, 10]), valid(7, "Ada", 15, [5]), bool.any([False, True]))
(list.any?([1, 2, 3], fn (n) -> int.gt?(n, 2)), real.between?(2.0, 1.0, 2.0))
