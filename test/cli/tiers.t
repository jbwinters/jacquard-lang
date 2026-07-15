Tier statistics for the native route (PF.2 phase 1): the same table
docs/native-compilation.md publishes for the prelude. Handler reporting keeps
syntactic resume shape separate from mode-aware native lowering: a tail-shaped
Once clause still materializes its affine token. Sig changes that move a row
tier land here on purpose, like the sigs goldens.

  $ export JACQUARD_PRELUDE=../../prelude

  $ jacquard tiers
  == declarations: 286 named terms ==
  pure                 193  67%
  row-poly              41  14%
  effectful             40  13%
  data                  12   4%
  
  == call sites: 1020 applications ==
  constructor          262  25%
  op-perform            47   4%
  fn pure              543  53%
  fn row-poly           61   5%
  fn effectful         107  10%
    abort                2
    audit                2
    check               34
    clock                1
    console              2
    dist                 7
    emit                 2
    fault                5
    fs                   4
    infer                4
    judge                4
    net                  9
    state                1
    throw               66
  
  == handler op clauses: 38 (syntactic resumption shape) ==
  tail-resumptive        9  23%
  aborting               6  15%
  one-shot               4  10%
  multi-shot            19  50%
  == native handler lowering: 38 (shape + operation mode) ==
  tokenless-tail-multi         1   2%
  materialized-resume         37  97%
    abort            once   aborting         materialized-resume        2
    assess           once   tail-resumptive  materialized-resume        3
    assess           once   multi-shot       materialized-resume        1
    check            multi  one-shot         materialized-resume        1
    check            multi  multi-shot       materialized-resume        2
    complete         once   multi-shot       materialized-resume        1
    emit             once   tail-resumptive  materialized-resume        1
    emit             once   one-shot         materialized-resume        1
    fail             multi  aborting         materialized-resume        1
    fetch            once   multi-shot       materialized-resume        4
    flaky            multi  tail-resumptive  tokenless-tail-multi       1
    flaky            multi  multi-shot       materialized-resume        2
    get              multi  multi-shot       materialized-resume        1
    list-dir         once   tail-resumptive  materialized-resume        1
    list-dir         once   multi-shot       materialized-resume        1
    now              once   tail-resumptive  materialized-resume        1
    observe          multi  one-shot         materialized-resume        1
    print            once   multi-shot       materialized-resume        1
    put              multi  multi-shot       materialized-resume        1
    read             once   tail-resumptive  materialized-resume        1
    read             once   multi-shot       materialized-resume        1
    read-line        once   multi-shot       materialized-resume        1
    record           once   one-shot         materialized-resume        1
    record           once   multi-shot       materialized-resume        1
    sample           multi  multi-shot       materialized-resume        1
    sleep            once   tail-resumptive  materialized-resume        1
    throw            once   aborting         materialized-resume        2
    write            once   aborting         materialized-resume        1
    write            once   multi-shot       materialized-resume        1
  
  stamped 286 tier sidecars

A file that does not resolve is an error, not a partial table:

  $ cat > bad.jqd <<'EOF_JQD'
  > (defterm ((binding boom () (app (var nowhere) (lit 1)))))
  > EOF_JQD
  $ jacquard tiers bad.jqd
  bad.jqd:1:33-46: error[E0301]: unknown name `nowhere`
  [1]

So is a file that resolves but does not typecheck, with source positions:

  $ cat > bad-type.jqd <<'EOF_JQD'
  > (defterm ((binding bad () (app (lit 1) (lit 2)))))
  > EOF_JQD
  $ jacquard tiers bad-type.jqd
  bad-type.jqd:1:27-48: error[E0802]: int is not a function
    hint: only functions, constructors, effect operations, and resumptions apply
  [1]
