weft run: declarations load, expressions evaluate and print (W2.7).

  $ export WEFT_PRELUDE=../../prelude

Factorial (decl + expression in one file):

  $ cat > fact.wft <<'EOF'
  > (defterm ((binding fact ()
  >   (lam ((pvar n))
  >     (match (var n)
  >       (clause (plit 0) (lit 1))
  >       (clause (pvar m)
  >         (app (var mul) (var m)
  >           (app (var fact) (app (var sub) (var m) (lit 1))))))))))
  > (app (var fact) (lit 5))
  > EOF
  $ weft run fact.wft
  120

The multi-shot Choose program:

  $ cat > choose.wft <<'EOF'
  > (defeffect choice ((tvar a)) (op choose () (tref bool)))
  > (handle
  >   (match (app (var choose))
  >     (clause (pcon true) (lit 1))
  >     (clause (pcon false) (lit 2)))
  >   (ret (pvar x) (var x))
  >   (opclause choose () k
  >     (tuple (app (var k) (var true)) (app (var k) (var false)))))
  > EOF
  $ weft run choose.wft
  (1, 2)

Console prints only under its grant (exit 3 = unhandled effect):

  $ cat > hello.wft <<'EOF'
  > (app (var print) (lit "hello weft\n"))
  > EOF
  $ weft run hello.wft --allow console
  hello weft
  ()
  $ weft run hello.wft
  unhandled effect console: operation `print` reached the root without a handler
  [3]

Runtime errors exit 2:

  $ cat > crash.wft <<'EOF'
  > (app (var div) (lit 1) (lit 0))
  > EOF
  $ weft run crash.wft
  arithmetic error: division by zero
  [2]

Diagnostics exit 1:

  $ cat > broken.wft <<'EOF'
  > (lit 1
  > EOF
  $ weft run broken.wft
  broken.wft:1:1-2:1: error[E0106]: unclosed form: expected `)`
  [1]
