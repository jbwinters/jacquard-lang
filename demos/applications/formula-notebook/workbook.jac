-- Edit this list to supply your own in-memory workbook/session.
nb.example-commands =
  [
    "set tickets = 80",
    "set price = 15",
    "set revenue = tickets * price",
    "set venue = 300",
    "set catering = tickets * 4",
    "set surplus = revenue - venue - catering",
    "show",
    "why surplus",
    "whatif tickets = 100",
    "show surplus",
    "set tickets = 100",
    "undo",
    "redo",
    "unset price",
    "set price = 18",
    "set tickets = surplus",
    "set price = (18 + )",
    "show",
    "quit",
  ]

nb.demo() = {
              let _ = nb.script(nb.empty(), nb.example-commands)
              ()}
