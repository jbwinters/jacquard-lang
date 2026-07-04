The committed transcript for demos/m4-hostile.sh (W5.5).

  $ export WEFT_PRELUDE=../../prelude

  $ weft check ../../demos/m4-hostile.wft --print-sigs
  fetch-title : (text) ->{net} text
  summarize : (text) ->{net} text
  _ : text
  $ weft check ../../demos/m4-hostile.wft --manifest console
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `net-fetch`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]
  $ weft check ../../demos/m4-hostile.wft --manifest net,console
  ok
  $ weft run ../../demos/m4-hostile.wft --allow net
  "<stub response for http://example.com>"
