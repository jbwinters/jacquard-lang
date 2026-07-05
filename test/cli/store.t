jacquard store: persistent store operations (W2.7). No implicit prelude here.

  $ cat > color.jqd <<'EOF'
  > (deftype color () (con red) (con green))
  > EOF
  $ jacquard store add mystore color.jqd
  ok
  $ ls mystore/objects | wc -l | tr -d ' '
  1

Bind an extra name to an existing hash:

  $ H=$(grep -o '#[0-9a-f]*' mystore/names.jqd | head -n 1 | tr -d '#')
  $ jacquard store name mystore crimson $H
  $ grep -c crimson mystore/names.jqd
  1

Rename touches only names.jqd:

  $ cp mystore/objects/* before.jqd
  $ jacquard store rename mystore color colour
  $ cmp before.jqd mystore/objects/*
  $ grep -c colour mystore/names.jqd
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

  $ cat > grp.jqd <<'EOF'
  > (defterm ((binding solo () (lit 1))))
  > EOF
  $ jacquard store add mystore grp.jqd
  ok
  $ G=$(ls mystore/objects | grep -v "$(grep -o '#[0-9a-f]*' mystore/names.jqd | head -n 1 | tr -d '#')" | head -n 1 | sed 's/\.jqd//')
  $ jacquard store name mystore the-group $G
  error[E0604]: cannot name a defterm group hash; name its members
  [1]
  $ cat > expr.jqd <<'EOF'
  > (lit 1)
  > EOF
  $ jacquard store add mystore expr.jqd
  error[E0704]: store add expects declarations only
  [1]

Origin provenance (PV.1): stamped at add, displayed by diff, absent cleanly.

  $ printf '(defterm ((binding fav () (lit 7))))\n' > fav.jqd
  $ printf '(defterm ((binding fav () (lit 8))))\n' > fav2.jqd
  $ jacquard store add prov-a fav.jqd
  ok
  $ jacquard store add prov-b fav2.jqd --origin agent:jacquard-demo-5
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
