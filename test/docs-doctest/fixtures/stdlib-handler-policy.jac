type Hash = | HashValue(value: Text)
type Authority =
  | Effect(name: Text)
  | Resource(effect-name: Text, scope: Text)
type OutcomeSummary = | OutcomeSummary(status: Text, digest: Hash, detail: Text)
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

once effect Approval where {
  approval.ask : (Proposal) -> Decision
}

dry-run-with-proposal(proposal-hash, workflow) =
  handle workflow() {
    | return result -> Some(result)
    | approval.ask(request) resume continue ->
        continue(Escalate(proposal-hash, "dry-run cannot consent"))
  }

proposal-hash = HashValue("proposal-v1")
proposal =
  Proposal(
    HashValue("subject"),
    HashValue("policy"),
    HashValue("assessment"),
    "ship?",
    [],
    None)

dry-run-with-proposal(proposal-hash, fn () -> match approval.ask(proposal) {
  | Escalate(HashValue("proposal-v1"), _) -> 42
  | Escalate(_, _) -> 0
  | Approved(_, _, _) -> 0
  | Denied(_, _, _) -> 0
})
