Tier statistics for the native route (PF.2 phase 1): the same table
docs/native-compilation.md publishes for the prelude. Sig changes that move a
row tier land here on purpose, like the sigs goldens.

  $ export JACQUARD_PRELUDE=../../prelude

  $ jacquard tiers
  == declarations: 197 named terms ==
  pure                 114  57%
  row-poly              39  19%
  effectful             32  16%
  data                  12   6%
  
  == call sites: 579 applications ==
  constructor          103  17%
  op-perform            45   7%
  fn pure              296  51%
  fn row-poly           93  16%
  fn effectful          42   7%
    abort                2
    check               10
    clock                1
    console              2
    dist                 1
    emit                 2
    fault                4
    fs                   2
    infer                1
    net                  6
    state                1
    throw               14
  
  == handler op clauses: 32 ==
  tail-resumptive        6  18%
  aborting               6  18%
  one-shot               3   9%
  multi-shot            17  53%
    abort            aborting           2
    check            one-shot           1
    check            multi-shot         2
    complete         multi-shot         1
    emit             tail-resumptive    1
    emit             one-shot           1
    fail             aborting           1
    fetch            multi-shot         4
    flaky            tail-resumptive    1
    flaky            multi-shot         2
    get              multi-shot         1
    list-dir         tail-resumptive    1
    list-dir         multi-shot         1
    now              tail-resumptive    1
    observe          one-shot           1
    print            multi-shot         1
    put              multi-shot         1
    read             tail-resumptive    1
    read             multi-shot         1
    read-line        multi-shot         1
    sample           multi-shot         1
    sleep            tail-resumptive    1
    throw            aborting           2
    write            aborting           1
    write            multi-shot         1
  
  stamped 197 tier sidecars

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
