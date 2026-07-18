type Bytes = | BytesValue(value: Text)
type Sql = | SqlValue(value: Text)
type Params = | ParamsValue(value: List Text)
type Rows = | RowsValue(value: List (List Text))
type Key = | KeyValue(value: Text)
type Signature = | SignatureValue(value: Bytes)
type LogEntry = | LogEntryValue(value: Text)

type Call =
  | Call(
      subject: Hash,
      operation: Text,
      arguments: Code,
      authority: List Authority,
      summary: Text,
      preconditions: Code)
type SecretRef = | SecretRef(name: Text, version: Option Text)
type Secret = | OpaqueSecret
type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled
type ChannelHandle a = | ChannelOpaque
type ChannelError = | ChannelClosed | InvalidCapacity(requested: Int)

once effect Env where {
  env.get : (Text) -> Option Text
}
once effect Pg where {
  pg.query : (Sql, Params) -> Rows
}
once effect Blob where {
  blob.get : (Hash) -> Option Bytes
  blob.put-if-absent : (Hash, Bytes) -> ()
  blob.exists? : (Hash) -> Bool
}
once effect Serve where {
  serve.next : () -> Request
  serve.respond : (Response) -> ()
}
once effect Crypto where {
  crypto.verify : (Key, Signature, Hash) -> Bool
  crypto.random : (Int) -> Bytes
}
once effect Log where {
  log.emit : (LogEntry) -> ()
}
once effect Secret where {
  secret.read : (SecretRef) -> Secret
  secret.expose : (Secret) -> Text
}
once effect Judge where {
  judge.assess : (Call) -> Assessment
}
once effect Async a where {
  async.spawn : (() ->{Async | e} a) -> Task a
  async.await : (Task a) -> TaskResult a
  async.cancel : (Task a) -> ()
  async.yield : () -> ()
}
once effect Channel a where {
  channel.open : (Int) -> Result ChannelError (ChannelHandle a)
  channel.send : (ChannelHandle a, a) -> Result ChannelError ()
  channel.recv : (ChannelHandle a) -> Result ChannelError a
  channel.close : (ChannelHandle a) -> ()
}
