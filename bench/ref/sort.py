# Python twin of bench/sort.jqd with the same heap discipline: merge sort
# over heap-allocated nodes, not the built-in sort over a flat list.
class Node:
    __slots__ = ('v', 'next')
    def __init__(self, v, nxt):
        self.v = v
        self.next = nxt
def merge(a, b):
    head = Node(0, None)
    t = head
    while a and b:
        if a.v <= b.v:
            t.next = a
            a = a.next
        else:
            t.next = b
            b = b.next
        t = t.next
    t.next = a if a else b
    return head.next
def msort(xs):
    if not xs or not xs.next:
        return xs
    a = b = None
    while xs:
        n = xs.next
        xs.next = a
        a = xs
        xs = n
        if xs:
            n = xs.next
            xs.next = b
            b = xs
            xs = n
    return merge(msort(a), msort(b))
xs = None
for i in range(200000):
    xs = Node(i, xs)
xs = msort(xs)
n = 0
while xs:
    n += 1
    xs = xs.next
print(n)
