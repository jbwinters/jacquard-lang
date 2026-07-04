The tutorial's command lines stay truthful (W5.4: every example runs in CI).

  $ export WEFT_PRELUDE=../../prelude

Examples 1 and 2 (literals and application):

  $ weft run ../../corpus/valid/lit-int.wft
  Usage: weft run [--help] [OPTION]… FILE
  weft: FILE argument: no ../../corpus/valid/lit-int.wft file or directory
  [124]
  $ weft run ../../corpus/valid/app-add.wft
  Usage: weft run [--help] [OPTION]… FILE
  weft: FILE argument: no ../../corpus/valid/app-add.wft file or directory
  [124]

Example 10 (content addressing):

  $ printf '(deftype color () (con red) (con green))\n' > color.wft
  $ weft store add lib-v1 color.wft
  ok
  $ weft store add lib-v2 color.wft
  ok
  $ weft store rename lib-v2 color colour
  $ weft diff lib-v1 lib-v2
  renamed  color -> colour

Diffing a store that does not exist is an error, not an empty result:

  $ weft diff lib-v1 nowhere
  error[E0606]: store nowhere does not exist
  [1]
