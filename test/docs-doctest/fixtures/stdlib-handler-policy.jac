parsed-hashes = (
  hash.parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
  hash.parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
  hash.parse("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"))

match parsed-hashes {
  | (Ok(subject-hash), Ok(policy-hash), Ok(assessment-hash)) -> {
      let proposal-value = approval.make-proposal(
        subject-hash,
        policy-hash,
        assessment-hash,
        [],
        quote { "ship" },
        "ship?",
        None)
      let proposal-hash = approval.proposal-id(proposal-value)
      throw.catch(
        fn () -> approval.dry-run(fn () -> match `op:ask`(proposal-value) {
	  | Escalate(returned, _) ->
		  if code.eq?(code.of-hash(returned), code.of-hash(proposal-hash)) then 42 else 0
	  | Approved(_, _, _) -> 0
	  | Denied(_, _, _) -> 0
        }),
        fn (message) -> 0)
    }
  | _ -> 0
}
