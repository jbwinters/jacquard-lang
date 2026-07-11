type Test =
  | Case Text (() ->{Check} ())
  | Prop Text (() ->{Dist, Check} ())
  | Group Text (List Test)

type WorldTest =
  | WCase Text (() ->{Check, Fs, Net, Clock, Console} ())
