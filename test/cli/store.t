jacquard store: persistent store operations (W2.7). No implicit prelude here.

  $ cat > color.wft <<'EOF'
  > (deftype color () (con red) (con green))
  > EOF
  $ jacquard store add mystore color.wft
  ok
  $ ls mystore/objects | wc -l | tr -d ' '
  1

Bind an extra name to an existing hash:

  $ H=$(grep -o '#[0-9a-f]*' mystore/names.wft | head -n 1 | tr -d '#')
  $ jacquard store name mystore crimson $H
  $ grep -c crimson mystore/names.wft
  1

Rename touches only names.wft:

  $ cp mystore/objects/* before.wft
  $ jacquard store rename mystore color colour
  $ cmp before.wft mystore/objects/*
  $ grep -c colour mystore/names.wft
  1

Failure paths:

  $ jacquard store rename mystore ghost gone
  error[E0602]: unknown name `ghost`
  [1]
  $ jacquard store name mystore bad zzzz
  error[E0104]: invalid hash
  [1]
  $ jacquard store name mystore ghost 0000000000000000000000000000000000000000000000000000000000000000
  error[E0601]: cannot name unknown hash 0000000000000000000000000000000000000000000000000000000000000000
  [1]

A defterm group's whole hash is not nameable (name its members):

  $ cat > grp.wft <<'EOF'
  > (defterm ((binding solo () (lit 1))))
  > EOF
  $ jacquard store add mystore grp.wft
  ok
  $ G=$(ls mystore/objects | grep -v "$(grep -o '#[0-9a-f]*' mystore/names.wft | head -n 1 | tr -d '#')" | head -n 1 | sed 's/\.wft//')
  $ jacquard store name mystore the-group $G
  error[E0604]: cannot name a defterm group hash; name its members
  [1]
  $ cat > expr.wft <<'EOF'
  > (lit 1)
  > EOF
  $ jacquard store add mystore expr.wft
  error[E0704]: store add expects declarations only
  [1]

Origin provenance (PV.1): stamped at add, displayed by diff, absent cleanly.

  $ printf '(defterm ((binding fav () (lit 7))))\n' > fav.wft
  $ printf '(defterm ((binding fav () (lit 8))))\n' > fav2.wft
  $ jacquard store add prov-a fav.wft
  ok
  $ jacquard store add prov-b fav2.wft --origin agent:jacquard-demo-5
  ok
  $ jacquard diff prov-a prov-b | head -1
  changed  fav [agent:jacquard-demo-5]
  $ jacquard diff prov-b prov-a | head -1
  changed  fav

The sidecar never breaks the identity self-check (the reopen-with-sidecar unit
test covers rename survival; here the contents differ across the stores, so
the diff shows add+remove):

  $ ls prov-b/objects/*.origin | wc -l
  1
  $ jacquard store rename prov-b fav favourite
  $ jacquard diff prov-a prov-b | head -1
  added    favourite
