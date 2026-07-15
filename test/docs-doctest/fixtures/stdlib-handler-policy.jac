type Authority =
  | Effect(name: Text)
  | Resource(effect-name: Text, scope: Text)
type Proposal =
  | Proposal(
      subject: Hash,
      policy: Hash,
      assessment: Hash,
      summary: Text,
      authority: List Authority,
      preview: Option OutcomeSummary)
once effect Approval where {
  approval.ask : (Proposal) -> Decision
}

dry-run-with-proposal(proposal-hash, workflow) =
  handle workflow() {
    | return result -> Some(result)
    | approval.ask(request) resume continue ->
        continue(Escalate(proposal-hash, "dry-run cannot consent"))
  }

parsed-hashes = (
  hash.parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
  hash.parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
  hash.parse("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
  hash.parse("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"))

match parsed-hashes {
  | (Ok(subject-hash), Ok(policy-hash), Ok(proposal-hash), Ok(assessment-hash)) -> {
      let proposal-value = Proposal(subject-hash, policy-hash, assessment-hash, "ship?", [], None)
      dry-run-with-proposal(proposal-hash, fn () -> match approval.ask(proposal-value) {
	| Escalate(returned, _) ->
		if code.eq?(code.of-hash(returned), code.of-hash(proposal-hash)) then 42 else 0
	| Approved(_, _, _) -> 0
	| Denied(_, _, _) -> 0
      })
    }
  | _ -> None
}
