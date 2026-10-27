type Decision =
  | Ship
  | Canary(percent: Int)
  | Hold(reason: Text)

type Result e a =
  | Err e
  | Ok a
