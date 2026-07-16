The committed transcript for demos/worlds/m4-hostile.sh (W5.5).

  $ export JACQUARD_PRELUDE=../../prelude

  $ jacquard check ../../demos/worlds/m4-hostile.jqd --print-sigs
  fetch-title : (Text) ->{Net} Text
  summarize : (Text) ->{Net} Text
  _ : Text
  $ jacquard check ../../demos/worlds/m4-hostile.jqd --manifest console
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `net.get`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]
  $ jacquard check ../../demos/worlds/m4-hostile.jqd --manifest net,console
  ok
  $ jacquard run ../../demos/worlds/m4-hostile.jqd --allow console
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `summarize`)
    hint: grant it with --allow net, or handle the effect in the program
  [3]
  $ jacquard run ../../demos/worlds/m4-hostile.jqd --allow net
  "<stub response for http://example.com>"
