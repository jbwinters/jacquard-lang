# Task-equivalent twin of bench/mutate.jqd — Python has no quoted code
# values; the counterpart runs the same single-edit mutant algorithm
# over the same tree mirrored as native tuples: a form is (head, args),
# an arg is a form, an int, or a symbol string. Spine rebuilds share
# unchanged children by reference, as the RC-shared forms do.
SUBJECT = ('lam', (('group', (('pvar', ('n',)),)),
                   ('app', (('var', ('add',)),
                            ('app', (('var', ('div',)),
                                     ('app', (('var', ('mul',)),
                                              ('var', ('n',)),
                                              ('app', (('var', ('sub',)),
                                                       ('var', ('n',)),
                                                       ('lit', (1,)))))),
                                     ('lit', (2,)))),
                            ('app', (('var', ('mul',)),
                                     ('lit', (3,)),
                                     ('app', (('var', ('add',)),
                                              ('var', ('n',)),
                                              ('lit', (4,))))))))))
OP_SWAPS = (('var', ('add',)), ('var', ('sub',)), ('var', ('mul',)))

def leaf_edits(c):
    out = []
    if c in OP_SWAPS:
        out += [(m, 'operator') for m in OP_SWAPS if m != c]
    if c[0] == 'lit' and isinstance(c[1][0], int):
        k = c[1][0]
        out += [(('lit', (k - 1,)), 'literal'), (('lit', (k + 1,)), 'literal')]
    return out

def un_form(c):
    head, args = c
    if all(isinstance(a, tuple) and isinstance(a[0], str) and isinstance(a[1], tuple)
           for a in args):
        return head, args
    return None

def code_mutants(c):
    out = leaf_edits(c)
    split = un_form(c)
    if split is None:
        return out
    head, children = split
    for i, child in enumerate(children):
        for m, kind in code_mutants(child):
            rebuilt = children[:i] + (m,) + children[i + 1:]
            out.append(((head, rebuilt), kind))
    return out

total = 0
for _ in range(300):
    total += len(code_mutants(SUBJECT))
print(total)
