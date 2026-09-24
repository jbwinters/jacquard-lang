Typed inference outcomes at the CLI (INF.1). `jacquard infer` separates a
posterior from impossible evidence (E0901), numerical failure (E0917) and an
exhausted terminal-path budget (E0918), using the same classification as the
prelude's dist.enumerate-v1 and dist.sample-lw-v1. `--metadata` adds one
line describing the run.

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > coin.jqd <<'M'
  > (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >   (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 0.7)) (var c)) (var c)))
  > M
  $ jacquard infer enumerate --metadata coin.jqd
  0.700000  true
  0.300000  false
  # method=exact-enumeration complete=true seed=none bound=unbounded explored=2
  $ jacquard infer lw --seed 42 --samples 400 --metadata coin.jqd
  0.716535  true
  0.283465  false
  # method=likelihood-weighting complete=false seed=42 bound=400 explored=400
  $ jacquard infer enumerate --max-branches 1 coin.jqd
  error[E0918]: Exact enumeration exceeded its terminal-path budget.
    Cause: exploration stopped at the terminal-path budget before every path was reached
    Next step: Raise --max-branches after reviewing the model's finite support size, or use likelihood weighting.
  [1]
  $ jacquard infer enumerate --max-branches 2 --metadata coin.jqd
  0.700000  true
  0.300000  false
  # method=exact-enumeration complete=true seed=none bound=2 explored=2
  $ jacquard infer enumerate --max-branches 0 coin.jqd
  Usage: jacquard infer enumerate [--help] [OPTION]… FILE
  jacquard: option '--max-branches': expected a positive integer, got "0"
  [124]
  $ jacquard infer lw --seed 1 --samples 0 coin.jqd
  Usage: jacquard infer lw [--help] [OPTION]… FILE
  jacquard: option '--samples': expected a positive integer, got "0"
  [124]

Impossible evidence, including a draw from a support with no mass:

  $ cat > impossible.jqd <<'M'
  > (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 0.0)) (var true)) (lit 1))
  > M
  $ jacquard infer enumerate impossible.jqd
  error[E0901]: The posterior is empty.
    Cause: the posterior is empty: every branch is impossible under the observations
    Next step: Change the model or observations so at least one execution branch has nonzero weight.
  [1]
  $ jacquard infer lw --seed 3 --samples 10 impossible.jqd
  error[E0901]: The posterior is empty.
    Cause: the posterior is empty: every run is impossible under the observations
    Next step: Change the model or observations so at least one execution branch has nonzero weight.
  [1]
  $ cat > zero-support.jqd <<'M'
  > (app (var sample) (app (var categorical)
  >   (app (var cons) (app (var mk-pair) (lit 1) (lit 0.0)) (var nil))))
  > M
  $ jacquard infer lw --seed 3 --samples 10 zero-support.jqd
  error[E0901]: The posterior is empty.
    Cause: the posterior is empty: every run is impossible under the observations
    Next step: Change the model or observations so at least one execution branch has nonzero weight.
  [1]

Sampling drops impossible runs rather than listing them with probability 0:

  $ cat > half.jqd <<'M'
  > (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >   (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1.0)) (var c)) (var c)))
  > M
  $ jacquard infer lw --seed 5 --samples 100 half.jqd
  1.000000  true

Factors are multiplied in model order, so this product is a subnormal, not zero:

  $ cat > order.jqd <<'M'
  > (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1e-200)) (var true))
  >   (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 3e-124)) (var true))
  >     (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 0.6)) (var true)) (lit 1))))
  > M
  $ jacquard infer enumerate order.jqd
  1.000000  1

Positive factors whose product underflows are not impossible:

  $ cat > underflow.jqd <<'M'
  > (let nonrec (pwild)
  >   (app (var observe) (app (var categorical) (app (var cons) (app (var mk-pair) (lit 1) (lit 1e-200)) (var nil))) (lit 1))
  >   (let nonrec (pwild)
  >     (app (var observe) (app (var categorical) (app (var cons) (app (var mk-pair) (lit 1) (lit 1e-200)) (var nil))) (lit 1))
  >     (lit 1)))
  > M
  $ jacquard infer enumerate underflow.jqd
  error[E0917]: Inference failed numerically.
    Cause: every possible path's weight underflowed to zero; the posterior is not representable
    Next step: Rescale the model's weights so every path weight and the total stay finite, nonnegative, and representable.
  [1]
  $ jacquard infer lw --seed 3 --samples 10 underflow.jqd
  error[E0917]: Inference failed numerically.
    Cause: every possible run's weight underflowed to zero; the posterior is not representable
    Next step: Rescale the model's weights so every path weight and the total stay finite, nonnegative, and representable.
  [1]

A path that underflows beside one that does not survives with probability 0:

  $ cat > mixed.jqd <<'M'
  > (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >   (match (var c)
  >     (clause (pcon true)
  >       (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1e-200)) (var true))
  >         (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1e-200)) (var true)) (lit 1))))
  >     (clause (pcon false) (lit 2))))
  > M
  $ jacquard infer enumerate mixed.jqd
  1.000000  2
  0.000000  1

Non-finite and negative weights:

  $ cat > negative.jqd <<'M'
  > (app (var sample) (app (var categorical)
  >   (app (var cons) (app (var mk-pair) (lit 1) (lit -0.5)) (var nil))))
  > M
  $ jacquard infer enumerate negative.jqd
  error[E0917]: Inference failed numerically.
    Cause: a path weight is negative
    Next step: Rescale the model's weights so every path weight and the total stay finite, nonnegative, and representable.
  [1]
  $ cat > overflow.jqd <<'M'
  > (app (var sample) (app (var categorical)
  >   (app (var cons) (app (var mk-pair) (lit 1) (lit 1e308))
  >     (app (var cons) (app (var mk-pair) (lit 2) (lit 1e308)) (var nil)))))
  > M
  $ jacquard infer enumerate overflow.jqd
  error[E0917]: Inference failed numerically.
    Cause: a path weight or the total mass is not finite
    Next step: Rescale the model's weights so every path weight and the total stay finite, nonnegative, and representable.
  [1]
