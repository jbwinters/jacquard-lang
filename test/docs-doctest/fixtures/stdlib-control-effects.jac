effect Abort a where {
  abort : () -> a
}

effect Throw e a where {
  throw : (e) -> a
}

effect State s where {
  get : () -> s
  put : (s) -> ()
}

effect Emit w where {
  emit : (w) -> ()
}
