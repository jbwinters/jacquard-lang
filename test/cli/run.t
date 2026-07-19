jacquard run: declarations load, expressions evaluate and print (W2.7).

  $ export JACQUARD_PRELUDE=../../prelude

Factorial (decl + expression in one file):

  $ cat > fact.jqd <<'EOF'
  > (defterm ((binding fact ()
  >   (lam ((pvar n))
  >     (match (var n)
  >       (clause (plit 0) (lit 1))
  >       (clause (pvar m)
  >         (app (var mul) (var m)
  >           (app (var fact) (app (var sub) (var m) (lit 1))))))))))
  > (app (var fact) (lit 5))
  > EOF
  $ jacquard run fact.jqd
  120

The multi-shot Choose program (the return clause wraps each branch into the
answer type; the op clause appends the two branch lists):

  $ cat > choose.jqd <<'EOF'
  > (defeffect choice ((tvar a)) (op choose () (tref bool)))
  > (defterm ((binding append ()
  >   (lam ((pvar xs) (pvar ys))
  >     (match (var xs)
  >       (clause (pcon nil) (var ys))
  >       (clause (pcon cons (pvar x) (pvar rest))
  >         (app (var cons) (var x) (app (var append) (var rest) (var ys)))))))))
  > (handle
  >   (match (app (var choose))
  >     (clause (pcon true) (lit 1))
  >     (clause (pcon false) (lit 2)))
  >   (ret (pvar x) (app (var cons) (var x) (var nil)))
  >   (opclause choose () k
  >     (app (var append) (app (var k) (var true)) (app (var k) (var false)))))
  > EOF
  $ jacquard run choose.jqd
  cons(1, cons(2, nil))

Console prints only under its grant (exit 3 = unhandled effect):

  $ cat > hello.jqd <<'EOF'
  > (app (var print) (lit "hello jacquard\n"))
  > EOF
  $ jacquard run hello.jqd --allow console
  hello jacquard
  ()
  $ jacquard run hello.jqd
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `print`).
    Next step: grant it with --allow console, or handle the effect in the program
  [3]

Runtime errors exit 2:

  $ cat > crash.jqd <<'EOF'
  > (app (var div) (lit 1) (lit 0))
  > EOF
  $ jacquard run crash.jqd
  error: Arithmetic operation failed
    Cause: arithmetic error: division by zero
    Next step: Correct the arithmetic inputs and run the program again.
  [2]

Diagnostics exit 1:

  $ cat > broken.jqd <<'EOF'
  > (lit 1
  > EOF
  $ jacquard run broken.jqd
  broken.jqd:1:1-2:1: error[E0106]: The source ended before the form was complete.
    Cause: unclosed form: expected `)`
    Next step: Complete the open form and its closing parenthesis.
  [1]
