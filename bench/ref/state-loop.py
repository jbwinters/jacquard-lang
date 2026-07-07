# Task-equivalent twin of bench/state-loop.jqd — Python has no effect
# handlers; the counterpart is a million get/put pairs as method calls
# on a state object.
class Cell:
    __slots__ = ('v',)
    def __init__(self):
        self.v = 0
    def get(self):
        return self.v
    def put(self, v):
        self.v = v

c = Cell()
for _ in range(1000000):
    c.put(c.get() + 1)
print(c.get())
