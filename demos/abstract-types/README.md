# Abstract types

Three library projects whose types are declared `opaque type`, and one client
application that depends on all three (docs/designs/abstract-types.md §4).
Only a library's own units construct or match its opaque type, so every value
a client holds has passed the library's checks.

| Project | Opaque type | Invariant | Entry points |
| --- | --- | --- | --- |
| `prob` | `ProbValue` | a real number in [0, 1], never NaN | `prob.of-real`, `prob.value`, `prob.complement`, `prob.both` |
| `nel` | `NelList a` | at least one element | `nel.of-list`, `nel.singleton`, `nel.head`, `nel.to-list`, `nel.map` |
| `req` | `ReqValid` | a non-blank name, an email with `@`, an age in 13..130 | `req.validate`, `req.name`, `req.email`, `req.age`, `req.reason` |

`req` also exports the transparent `ReqInvalid` reasons, which clients may
construct and match.

    jac project test --project demos/abstract-types/prob
    jac project run --project demos/abstract-types/client demo --allow console

`client/EXAMPLE.txt` is the recorded transcript; `test/cli/abstract-types-demos.t`
checks it under the interpreter and natively, shows that a library may not
export its sealed constructor (E1736), and that the client's own attempts to
construct or match a sealed value are refused (E1705).
