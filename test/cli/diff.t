jacquard diff: semantic comparison of two stores (W5.2).

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > lib.jqd <<'EOF_JQD'
  > (deftype color () (con red) (con green))
  > (defterm ((binding pick () (lam ((pvar b)) (match (var b) (clause (pcon red) (lit 1)) (clause (pcon green) (lit 2)))))))
  > EOF_JQD
  $ jacquard store add a lib.jqd
  ok
  $ jacquard store add b lib.jqd
  ok

A rename is exactly a rename, in both the default report and `--paths`:

  $ jacquard store rename b pick choose
  $ jacquard diff a b
  renamed  pick -> choose
  $ jacquard diff a b --paths
  renamed  pick -> choose

A literal edit localizes to the changed leaf. The default report names the region (here the first
match clause of the body); `--paths` prints the kernel path for tools:

  $ cat > lib2.jqd <<'EOF_JQD'
  > (deftype color () (con red) (con green))
  > (defterm ((binding pick () (lam ((pvar b)) (match (var b) (clause (pcon red) (lit 9)) (clause (pcon green) (lit 2)))))))
  > EOF_JQD
  $ jacquard store add c lib2.jqd
  ok
  $ jacquard diff a c
  changed  pick
    clause 1   1  ->  9
  $ jacquard diff a c --paths > pipe.out || echo "exit=$?"; grep -E 'changed|lit' < pipe.out
  changed  pick
    at pick/defterm[0]/group[0]/binding[2]/lam[1]/match[1]/clause[1]/lit[0]:

Identical stores have no semantic changes:

  $ jacquard diff a a
  no semantic changes

Resolved effect rows receive an identity-keyed authority review, not a string-only diff:

  $ cat > old-authority.jqd <<'EOF_JQD'
  > (defterm ((binding policy ((tarrow () (row (eref fs)) (tref int))) (lam () (lit 1)))))
  > EOF_JQD
  $ cat > new-authority.jqd <<'EOF_JQD'
  > (defterm ((binding policy ((tarrow () (row (eref net)) (tref int))) (lam () (lit 1)))))
  > EOF_JQD
  $ jacquard diff old-authority.jqd new-authority.jqd
  changed  policy
    authority  {Fs}  ->  {Net}
      - Fs [world/medium] — read or mutate the filesystem under the granted root handler
      + Net [world/high] — reach a network endpoint through the granted handler
  $ jacquard diff old-authority.jqd new-authority.jqd --paths
  changed  policy
    at policy/defterm[0]/group[0]/binding[1]/group[0]/tarrow[1]:
      - authority {Fs [world/medium] — read or mutate the filesystem under the granted root handler}
      + authority {Net [world/high] — reach a network endpoint through the granted handler}

User effects remain identity-visible and unrated in the same authority diff,
even when both versions reuse one local name:

  $ cat > old-user-authority.jqd <<'EOF_JQD'
  > (defeffect custom () (op use once () (tref int)))
  > (defterm ((binding policy ((tarrow () (row (eref custom)) (tref int))) (lam () (lit 1)))))
  > EOF_JQD
  $ cat > new-user-authority.jqd <<'EOF_JQD'
  > (defeffect custom () (op use once () (tref text)))
  > (defterm ((binding policy ((tarrow () (row (eref custom)) (tref int))) (lam () (lit 1)))))
  > EOF_JQD
  $ jacquard diff old-user-authority.jqd new-user-authority.jqd
  changed  custom
    op use     Int  ->  Text
    dependents: policy
  changed  policy
    authority  {custom#f32431aafb35}  ->  {custom#e5a04705ef6a}
      - unpackaged:f32431aafb35/custom [unrated user effect #f32431aafb35ef647194bd1f8ee2fee3278f49e61fc218c72daba69a81f72e26]
      + unpackaged:e5a04705ef6a/custom [unrated user effect #e5a04705ef6a4df51a0d4529d738941a3e428e4cf4341b95e65fbd030da88cec]
  changed  use
    op use     Int  ->  Text
  $ jacquard diff old-user-authority.jqd new-user-authority.jqd --paths
  changed  custom
    at custom/defeffect[2]/op[3]/tref[0]:
      - #907085f5670ab5835e5356feb10ae729496e3816b863ddbb21cfe289e7d34f0d
      + #ca456459bd7fbe8c9694388e1246c4333221817248d24707f05b7423828516e3
    dependents: policy
  changed  policy
    at policy/defterm[0]/group[0]/binding[1]/group[0]/tarrow[1]:
      - authority {unpackaged:f32431aafb35/custom [unrated user effect #f32431aafb35ef647194bd1f8ee2fee3278f49e61fc218c72daba69a81f72e26]}
      + authority {unpackaged:e5a04705ef6a/custom [unrated user effect #e5a04705ef6a4df51a0d4529d738941a3e428e4cf4341b95e65fbd030da88cec]}
  changed  use
    at use/defeffect[2]/op[3]/tref[0]:
      - #907085f5670ab5835e5356feb10ae729496e3816b863ddbb21cfe289e7d34f0d
      + #ca456459bd7fbe8c9694388e1246c4333221817248d24707f05b7423828516e3

Surface sources read the same way. A reformat with comments is no change in either mode:

  $ cat > v1.jac <<'EOF'
  > normalize-name : (Text) ->{} Text
  > normalize-name(name) = text.trim(name)
  > greet(name) = text.concat("hi ", normalize-name(name))
  > EOF
  $ cat > v1-reformatted.jac <<'EOF'
  > -- the same definitions, reformatted and commented
  > normalize-name : (Text) ->{} Text
  > normalize-name(name) =
  >   text.trim(name)
  > greet(name) = text.concat( "hi ", normalize-name(name) )
  > EOF
  $ jac diff v1.jac v1-reformatted.jac
  no semantic changes
  $ jac diff v1.jac v1-reformatted.jac --paths
  no semantic changes

A body change that adds a call widens the authority. The default report names the new callee, shows
the added definition's signature and the reviewer meaning of the added effect; a dependent whose
callee changed identity shows both identities, since its name reads the same:

  $ cat > v2.jac <<'EOF'
  > lookup-alias : (Text) ->{Net} Text
  > lookup-alias(name) = { let _ = fetch(MkRequest(name, "")); name }
  > normalize-name : (Text) ->{Net} Text
  > normalize-name(name) = text.trim(lookup-alias(name))
  > greet(name) = text.concat("hi ", normalize-name(name))
  > EOF
  $ jac diff v1.jac v2.jac
  changed  greet
    body       normalize-name#ccf28f9616ad  ->  normalize-name#6e2d8afffe22
  added    lookup-alias : (Text) ->{Net} Text
  changed  normalize-name
    authority  {}  ->  {Net}
      + Net [world/high] — reach a network endpoint through the granted handler
    body       name  ->  lookup-alias(name)
    dependents: greet
  $ jac diff v1.jac v2.jac --paths
  changed  greet
    at greet/defterm[0]/group[0]/binding[2]/lam[1]/app[2]/app[0]/ref[0]:
      - #ccf28f9616ad20b29dba83a975c79aac825977e45842d1de969efe0a2985d27c
      + #6e2d8afffe22d3d272713270f0c5ec1d66243240eb3d0c49057df13ee76fb894
  added    lookup-alias
  changed  normalize-name
    at normalize-name/defterm[0]/group[0]/binding[1]/group[0]/tarrow[1]:
      - authority {}
      + authority {Net [world/high] — reach a network endpoint through the granted handler}
    at normalize-name/defterm[0]/group[0]/binding[2]/lam[1]/app[1]:
      - name
      + #097a33fe0b7519805d497d433a75f70bb8d9d63e940000558a8e2f06afcdca25:term(name)
    dependents: greet

A callee edit lists its dependents:

  $ cat > v3.jac <<'EOF'
  > normalize-name : (Text) ->{} Text
  > normalize-name(name) = text.concat(text.trim(name), "!")
  > greet(name) = text.concat("hi ", normalize-name(name))
  > EOF
  $ jac diff v1.jac v3.jac
  changed  greet
    body       normalize-name#ccf28f9616ad  ->  normalize-name#94aa82af2fff
  changed  normalize-name
    body       text.trim(name)  ->  text.concat(text.trim(name), "!")
    dependents: greet
  $ jac diff v1.jac v3.jac --paths
  changed  greet
    at greet/defterm[0]/group[0]/binding[2]/lam[1]/app[2]/app[0]/ref[0]:
      - #ccf28f9616ad20b29dba83a975c79aac825977e45842d1de969efe0a2985d27c
      + #94aa82af2fff4cdc74bee6453e669e2e3d063cc04b1a880ca096913307d928f2
  changed  normalize-name
    at normalize-name/defterm[0]/group[0]/binding[2]/lam[1]:
      - #5cfd7d8ba3f8cb9606a0dd0149a3c8605af431f7d52fd0ec4b54aa5aa5b1e4c3:term(name)
      + #0fb7430a9b9e5a4042cd6e11f14cf2ac475962fa28a8df583749af40f534b79c:term(
    #5cfd7d8ba3f8cb9606a0dd0149a3c8605af431f7d52fd0ec4b54aa5aa5b1e4c3:term(name),
    "!",
  )
    dependents: greet
  $ printf 'normalize-name : (Text) ->{} Text\nnormalize-name(name) = text.trim(name)\n\nhello(name) = text.concat("hi ", normalize-name(name))\n' > v4.jac
  $ jac diff v1.jac v4.jac
  renamed  greet -> hello
  $ jac diff v1.jac v4.jac --paths
  renamed  greet -> hello
