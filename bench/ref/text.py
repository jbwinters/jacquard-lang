# Python twin of bench/text.jqd. The two-chained adds at module scope
# defeat CPython's uniquely-referenced in-place append, so this loop is
# quadratic-or-worse like the immutable engines' concat (verified: 4x
# the input takes well over the quadratic 16x on this box, since the
# large temporaries also cross the allocator's mmap threshold).
s = ""
for i in range(10000):
    s = s + "," + str(i)
print(len(s.split(",")))
