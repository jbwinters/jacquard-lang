# Python twin of bench/sum.jqd: materialize the list, fold with a lambda
# (reduce over a bare range would skip the allocation the Jacquard
# program pays; the list() keeps the comparison honest)
from functools import reduce
print(reduce(lambda a, x: a + x, list(range(1000000)), 0))
