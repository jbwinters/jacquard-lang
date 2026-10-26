multi effect Choice where {
  choose : () -> Bool
}

once effect Abort a where {
  abort : () -> a
}

once effect Sending where {
  send : (path: Text, body: Text) -> Text
}
