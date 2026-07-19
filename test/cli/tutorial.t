The tutorial's command lines stay truthful (W5.4: every example runs in CI).

  $ export JACQUARD_PRELUDE=../../prelude

Examples 1 and 2 (literals and application):

  $ jacquard run ../../corpus/valid/lit-int.jqd
  1
  $ jacquard run ../../corpus/valid/app-add.jqd
  3

Example 10 (content addressing):

  $ printf '(deftype color () (con red) (con green))\n' > color.jqd
  $ jacquard store add lib-v1 color.jqd
  ok
  $ jacquard store add lib-v2 color.jqd
  ok
  $ jacquard store rename lib-v2 color colour
  $ jacquard diff lib-v1 lib-v2
  renamed  color -> colour

Diffing a store that does not exist is an error, not an empty result:

  $ jacquard diff lib-v1 nowhere
  error[E0606]: Requested store is unavailable
    Cause: store nowhere does not exist
    Next step: Pass the path to an existing Jacquard store.
  [1]
