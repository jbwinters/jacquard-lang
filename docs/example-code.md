These are historical pre-implementation sketches in bootstrap s-expression
notation from the dev plan (W1.2). They are retained as kernel design context,
not as the current quick start. For executable surface programs use
`tutorial.md` and the `.jac` catalog in `../demos/README.md`; bootstrap `.jqd`
remains the internal/debug and format-of-record carrier.

**1. Safe division, failure as an effect handled to Option.** Exercises match-instead-of-if, exhaustiveness, Handle with a return clause, and a clause that never resumes.

```lisp
; safeDiv n d = match d == 0 { true -> abort; false -> n / d }
(defterm ((binding safe-div ()
  (lam ((pvar n) (pvar d))
    (match (app (var eq) (var d) (lit 0))
      (clause (pcon true)  (app (var abort)))
      (clause (pcon false) (app (var div) (var n) (var d))))))))

; toOption thunk = handle thunk() { return x -> Some x; abort k -> None }
(defterm ((binding to-option ()
  (lam ((pvar body))
    (handle (app (var body))
      (ret (pvar x) (app (var some) (var x)))
      (opclause abort () k (var none)))))))

(defterm ((binding main ()
  (tuple
    (app (var to-option) (lam () (app (var safe-div) (lit 10) (lit 2))))
    (app (var to-option) (lam () (app (var safe-div) (lit 1)  (lit 0))))))))
```

Running it gives `(Some 5, None)`. What `jacquard check --print-sigs` should print is the actual point:

```
safe-div  : (Int, Int) ->{Abort} Int
to-option : forall a | e. (() ->{Abort | e} a) ->{| e} Option a
main      : (Option Int, Option Int)
```

The first line announces the failure. The second shows row polymorphism earning its keep: to-option removes Abort and passes everything else through. Main's row is empty because everything got handled, so it runs with zero grants.

**2. Two coins, the M3 flagship model.** Condition-via-observe using the Bernoulli(1.0) trick, which works directly with the pmf semantics pinned in task W4.2.

```lisp
; historical bootstrap counterpart of: jac infer enumerate demos/inference/m3-two-coins.jac
(defterm ((binding condition ()
  (lam ((pvar b))
    (app (var observe) (app (var bernoulli) (lit 1.0)) (var b))))))

; model = { a <- coin; b <- coin; condition (a or b); a }
(defterm ((binding model ()
  (lam ()
    (let (pvar a) (app (var sample) (app (var bernoulli) (lit 0.5)))
    (let (pvar b) (app (var sample) (app (var bernoulli) (lit 0.5)))
    (let (pwild)  (app (var condition) (app (var or) (var a) (var b)))
    (var a))))))))
```

Signature: `model : () ->{Dist} Bool`, which is the whole thesis in one line, since the row announces that this denotes a distribution rather than a value. Enumerate should print `true 0.6667, false 0.3333` (the 2/3 posterior), and the likelihood-weighting handler run against the byte-identical file should converge to the same numbers.

**3. Six lines of homoiconicity plus capability gating.**

```lisp
; main = eval 'quote(add 1 ~(quote 41))'   -- needs --allow Eval
(defterm ((binding main ()
  (app (var eval)
    (quote (app (var add) (lit 1) (unquote (quote (lit 41)))))))))
```

Under `jacquard run --allow Eval` this splices, evaluates, and prints 42. Without the grant it never runs at all: main's row contains Eval, so the W3.6 manifest check refuses at the type level and names the effect. Code running code is an authority like any other.

Two small notation calls I made that W1.2 didn't pin, worth folding back into that task so the examples and the reader agree: `let` defaults to non-recursive when the flag is omitted, and op or constructor names appear as bare symbols pre-resolution (`abort`, `pcon true`) with the resolver assigning the ref kind. Both are one-line reader decisions, and these three files would make decent first residents of the corpus.
