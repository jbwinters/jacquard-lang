Tier statistics for the native route (PF.2 phase 1): the same table
docs/native-compilation.md publishes for the prelude. Handler reporting keeps
syntactic resume shape separate from mode-aware native lowering: a tail-shaped
Once clause still materializes its affine token. Sig changes that move a row
tier land here on purpose, like the sigs goldens.

  $ export JACQUARD_PRELUDE=../../prelude

  $ jacquard tiers
  == declarations: 362 named terms ==
  pure                 245  67%
  row-poly              44  12%
  effectful             54  14%
  data                  19   5%
  
  == call sites: 1419 applications ==
  constructor          401  28%
  op-perform            71   5%
  fn pure              722  50%
  fn row-poly          129   9%
  fn effectful          96   6%
    abort                2
    approval             4
    audit               15
    check               10
    clock                1
    console              3
    dist                 1
    emit                 2
    fault                4
    fs                   6
    governance-approval-v1     6
    infer                4
    judge               14
    net                  9
    secret               3
    state               23
    throw               30
    workspace            2
  
  == handler op clauses: 49 (syntactic resumption shape) ==
  tail-resumptive       15  30%
  aborting               6  12%
  one-shot               7  14%
  multi-shot            21  42%
  == native handler lowering: 49 (shape + operation mode) ==
  tokenless-tail-multi         1   2%
  materialized-resume         48  97%
    abort            once   aborting         materialized-resume        2
    ask              once   one-shot         materialized-resume        3
    ask              once   multi-shot       materialized-resume        1
    assess           once   tail-resumptive  materialized-resume        3
    assess           once   multi-shot       materialized-resume        1
    check            multi  one-shot         materialized-resume        1
    check            multi  multi-shot       materialized-resume        2
    complete         once   multi-shot       materialized-resume        1
    emit             once   tail-resumptive  materialized-resume        1
    emit             once   one-shot         materialized-resume        1
    fail             multi  aborting         materialized-resume        1
    fetch            once   tail-resumptive  materialized-resume        2
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
    read-file        once   tail-resumptive  materialized-resume        2
    read-line        once   multi-shot       materialized-resume        1
    record           once   one-shot         materialized-resume        1
    record           once   multi-shot       materialized-resume        1
    sample           multi  multi-shot       materialized-resume        1
    sleep            once   tail-resumptive  materialized-resume        1
    throw            once   aborting         materialized-resume        2
    write            once   aborting         materialized-resume        1
    write            once   multi-shot       materialized-resume        1
    write-file       once   tail-resumptive  materialized-resume        2
  
  stamped 362 tier sidecars

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
