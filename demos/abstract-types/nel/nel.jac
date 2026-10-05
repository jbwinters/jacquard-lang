-- A non-empty list as an opaque type: a NelList always has a head, so nel.head
-- needs no Option, and clients can only obtain one through nel.of-list or
-- nel.singleton.
opaque type NelList a = NelList(head: a, tail: List a)

nel.of-list(xs) = match xs { | Nil -> None | Cons(x, rest) -> Some(NelList(x, rest)) }

nel.singleton(x) = NelList(x, [])

nel.head(n) = match n { | NelList(x, _) -> x }

nel.to-list(n) = match n { | NelList(x, rest) -> Cons(x, rest) }

nel.map(n, f) = match n { | NelList(x, rest) -> NelList(f(x), list.map(rest, f)) }
