type Hash = | HashValue(value: Text)
type Bytes = | BytesValue(value: Text)
type Sql = | SqlValue(value: Text)
type Params = | ParamsValue(value: List Text)
type Rows = | RowsValue(value: List (List Text))
type Key = | KeyValue(value: Text)
type Signature = | SignatureValue(value: Bytes)
type LogEntry = | LogEntryValue(value: Text)

type Risk = | Low | Medium | High | Forbidden
type Verdict = | Allow | Simulate | Ask | Block
type Authority =
  | Effect(name: Text)
  | Resource(effect-name: Text, scope: Text)
type Call =
  | Call(
      subject: Hash,
      operation: Text,
      arguments: Code,
      authority: List Authority,
      summary: Text,
      preconditions: Code)
type Assessment =
  | Assessment(risk: Risk, confidence: Real, reasons: List Text, evidence: Code)
type OutcomeSummary =
  | OutcomeSummary(status: Text, digest: Hash, detail: Text)
type Proposal =
  | Proposal(
      subject: Hash,
      policy: Hash,
      assessment: Hash,
      summary: Text,
      authority: List Authority,
      preview: Option OutcomeSummary)
type Decision =
  | Approved(proposal: Hash, approver: Text, evidence: Code)
  | Denied(proposal: Hash, approver: Text, reason: Text)
  | Escalate(proposal: Hash, reason: Text)
type AuditEntry =
  | Evaluated(call: Hash, policy: Hash, assessment: Assessment, verdict: Verdict)
  | Consented(call: Hash, proposal: Hash, decision: Decision)
  | Completed(call: Hash, branch: Text, outcome: OutcomeSummary)
type SecretRef = | SecretRef(name: Text, version: Option Text)
type Secret = | OpaqueSecret
type Task a = | TaskHandle(id: Int)
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled
type ChannelHandle a = | ChannelHandleValue(id: Int)
type ChannelError = | ChannelClosed

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
once effect Approval where {
  approval.ask : (Proposal) -> Decision
}
once effect Audit where {
  audit.record : (AuditEntry) -> ()
}
once effect Secret where {
  secret.read : (SecretRef) -> Secret
  secret.expose : (Secret) -> Text
}
once effect Judge where {
  judge.assess : (Call) -> Assessment
}
once effect Channel a where {
  channel.open : () -> ChannelHandle a
  channel.send : (ChannelHandle a, a) -> Result ChannelError ()
  channel.recv : (ChannelHandle a) -> Result ChannelError a
  channel.close : (ChannelHandle a) -> ()
}
