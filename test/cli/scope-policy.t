This transcript runs an OCaml evidence helper directly, not `jacquard run`.
It proves the two library policy shapes and does not claim that
`async.scope-fail-fast` or `async.scope-collect` is a public Jacquard term.
SC.8 consumes explicit scheduler decision order; running the same policy trace
twice is byte-identical and aggregation remains in creation/input order.

  $ ../scope_policy_trace.exe > first.out
  $ ../scope_policy_trace.exe > second.out
  $ cmp first.out second.out
  $ cat first.out
  fail-fast decision=7 result=failed(first) dropped=21,31
  collect input-order=[done(10),failed(later),done(30)]
