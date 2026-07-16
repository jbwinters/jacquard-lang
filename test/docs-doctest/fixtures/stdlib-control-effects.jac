once effect Abort a where {
  abort : () -> a
}

once effect Throw e a where {
  throw : (e) -> a
}

multi effect State s where {
  get : () -> s
  put : (s) -> ()
}

once effect Emit w where {
  emit : (w) -> ()
}
