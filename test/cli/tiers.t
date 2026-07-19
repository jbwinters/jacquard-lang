Tier statistics for the native route (PF.2 phase 1): the same table
docs/native-compilation.md publishes for the prelude. Handler reporting keeps
syntactic resume shape separate from mode-aware native lowering: a tail-shaped
Once clause still materializes its affine token. Sig changes that move a row
tier land here on purpose, like the sigs goldens.

  $ export JACQUARD_PRELUDE=../../prelude

  $ jacquard tiers
  == declarations: 357 named terms ==
  pure                 245  68%
  row-poly              44  12%
  effectful             49  13%
  data                  19   5%
  
  == call sites: 1375 applications ==
  constructor          392  28%
  op-perform            66   4%
  fn pure              713  51%
  fn row-poly          120   8%
  fn effectful          84   6%
    abort                2
    approval             4
    audit                7
    check               10
    clock                1
    console              3
    dist                 1
    emit                 2
    fault                4
    fs                   2
    governance-approval-v1     1
    infer                4
    judge                9
    net                  6
    state               16
    throw               30
    workspace            1
  
  == handler op clauses: 46 (syntactic resumption shape) ==
  tail-resumptive       12  26%
  aborting               6  13%
  one-shot               7  15%
  multi-shot            21  45%
  == native handler lowering: 46 (shape + operation mode) ==
  tokenless-tail-multi         1   2%
  materialized-resume         45  97%
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
    fetch            once   tail-resumptive  materialized-resume        1
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
    read-file        once   tail-resumptive  materialized-resume        1
    read-line        once   multi-shot       materialized-resume        1
    record           once   one-shot         materialized-resume        1
    record           once   multi-shot       materialized-resume        1
    sample           multi  multi-shot       materialized-resume        1
    sleep            once   tail-resumptive  materialized-resume        1
    throw            once   aborting         materialized-resume        2
    write            once   aborting         materialized-resume        1
    write            once   multi-shot       materialized-resume        1
    write-file       once   tail-resumptive  materialized-resume        1
  
  stamped 357 tier sidecars

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
