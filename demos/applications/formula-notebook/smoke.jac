nb.smoke() =
  {
    let first = nb.commit(nb.empty(), NbSet("total", "count * (2 + 3)"))
    let second = nb.commit(nb.outcome-book(first), NbSet("count", "-7 / 3"))
    println(nb.value-text(nb.visible-value(nb.current(nb.outcome-book(second)), "total")))
  }

nb.smoke()
