Tier statistics for the native route (PF.2 phase 1): the same table
docs/native-compilation.md publishes for the prelude. Handler reporting keeps
syntactic resume shape separate from mode-aware native lowering: a tail-shaped
Once clause still materializes its affine token. Sig changes that move a row
tier land here on purpose, like the sigs goldens.

  $ export JACQUARD_PRELUDE=../../prelude

  $ jacquard tiers
  == declarations: 373 named terms ==
  pure                 252  67%
  row-poly              44  11%
  effectful             56  15%
  data                  21   5%
  
  == call sites: 1478 applications ==
  constructor          418  28%
  op-perform            77   5%
  fn pure              740  50%
  fn row-poly          138   9%
  fn effectful         105   7%
    abort                2
    approval             4
    audit               21
    check               10
    clock                1
    console              3
    dist                 1
    emit                 2
    fault                4
    fs                   6
    governance-approval-v1     9
    infer                4
    judge               18
    net                  9
    secret               3
    state               29
    throw               32
    workspace            3
  
  == handler op clauses: 53 (syntactic resumption shape) ==
  tail-resumptive       18  33%
  aborting               6  11%
  one-shot               8  15%
  multi-shot            21  39%
  == native handler lowering: 53 (shape + operation mode) ==
  tokenless-tail-multi         1   1%
  materialized-resume         52  98%
    abort            once   aborting         materialized-resume        2
    ask              once   one-shot         materialized-resume        3
    ask              once   multi-shot       materialized-resume        1
    assess           once   tail-resumptive  materialized-resume        3
    assess           once   one-shot         materialized-resume        1
    assess           once   multi-shot       materialized-resume        1
    check            multi  one-shot         materialized-resume        1
    check            multi  multi-shot       materialized-resume        2
    complete         once   multi-shot       materialized-resume        1
    emit             once   tail-resumptive  materialized-resume        1
    emit             once   one-shot         materialized-resume        1
    fail             multi  aborting         materialized-resume        1
    fetch            once   tail-resumptive  materialized-resume        3
    fetch            once   multi-shot       materialized-resume        4
    flaky            multi  tail-resumptive  tokenless-tail-multi       1
    flaky            multi  multi-shot       materialized-resume        2
    get              multi  multi-shot       materialized-resume        1
    governance-approval.ask once   multi-shot       materialized-resume        1
    list-dir         once   tail-resumptive  materialized-resume        1
    list-dir         once   multi-shot       materialized-resume        1
    now              once   tail-resumptive  materialized-resume        1
    observe          multi  one-shot         materialized-resume        1
    print            once   multi-shot       materialized-resume        1
    put              multi  multi-shot       materialized-resume        1
    read             once   tail-resumptive  materialized-resume        1
    read             once   multi-shot       materialized-resume        1
    read-file        once   tail-resumptive  materialized-resume        3
    read-line        once   multi-shot       materialized-resume        1
    record           once   one-shot         materialized-resume        1
    record           once   multi-shot       materialized-resume        1
    sample           multi  multi-shot       materialized-resume        1
    sleep            once   tail-resumptive  materialized-resume        1
    throw            once   aborting         materialized-resume        2
    write            once   aborting         materialized-resume        1
    write            once   multi-shot       materialized-resume        1
    write-file       once   tail-resumptive  materialized-resume        3
  
  stamped 373 tier sidecars

A file that does not resolve is an error, not a partial table:

  $ cat > bad.jqd <<'EOF_JQD'
  > (defterm ((binding boom () (app (var nowhere) (lit 1)))))
  > EOF_JQD
  $ jacquard tiers bad.jqd
  bad.jqd:1:33-46: error[E0301]: This reference names something that is not in scope.
    Cause: No name named `nowhere` is in scope.
    Next step: Correct the reference to an in-scope name or declaration.
  [1]

So is a file that resolves but does not typecheck, with source positions:

  $ cat > bad-type.jqd <<'EOF_JQD'
  > (defterm ((binding bad () (app (lit 1) (lit 2)))))
  > EOF_JQD
  $ jacquard tiers bad-type.jqd
  bad-type.jqd:1:27-48: error[E0802]: This value is not callable
    Cause: int is not a function
    Next step: Apply only a function, constructor, effect operation, or resumption.
  [1]
