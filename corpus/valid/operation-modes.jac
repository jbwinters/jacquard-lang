once effect Gate where {
  enter : () -> ()
}

multi effect Choice where {
  choose : () -> ()
}

effect Control where {
  once stop : () -> ()
  multi branch : () -> ()
}
