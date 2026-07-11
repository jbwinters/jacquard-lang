read-note() = fs.read-only(fn () -> {
  let contents = read("note.txt")
  write("note.txt", "clobbered")
  contents
})
