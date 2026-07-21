-- Demo-specific Warp laws. run.sh assembles this after the unchanged agent and
-- its deterministic interpreters.
governed-workspace-suite =
  Group("governed workspace",
    [Case("dry run simulates all four calls without raw authority",
       fn () ->
         match dry-world() {
           | Ok((Ok(MkResponse(202, "dry deployment accepted")), entries)) -> {
             check.eq(list.length(entries), 8, int.eq, int.show, "audit entries")
             check.true(True, "the inferred row is empty after pure handlers")
           }
           | _ -> check.true(False, "unexpected dry-run result")}),
     Case("inner allow forwards the same call to outer block",
       fn () ->
         {
           let verdicts =
             throw.to-result(
               fn () ->
                 (governance.live-policy-verdict(bind-live-policy(Medium, High), Medium, 0.9),
                  governance.live-policy-verdict(bind-live-policy(Low, Low), Medium, 0.9)))
           match (verdicts, nested-refusal-world()) {
             | (Ok((Ok(Allow), Ok(Block))), Ok(((Err(ToolBlocked(_)), 0), entries))) ->
               check.eq(list.length(entries), 3, int.eq, int.show, "ordered audit entries")
             | _ -> check.true(False, "unexpected nested refusal trace")
           }}),
     Case("a denial is bound to the exact deployment proposal",
       fn () ->
         {
           let proposal-result = throw.to-result(fn () -> deployment-proposal())
           match proposal-result {
             | Ok(proposal-value) -> {
               let proposal-id = governance.proposal-id(proposal-value)
               let decision = Denied(proposal-id, "reviewer", "release held")
               match governance.approval.validate-decision(proposal-value, decision) {
                 | Ok(Denied(embedded, "reviewer", "release held")) ->
                   check.true(governance.hash-eq?(proposal-id, embedded),
                     "Decision embeds this exact proposal")
                 | _ -> check.true(False, "exact denial was not accepted")
               }
             }
             | _ -> check.true(False, "exact denial was not accepted")
           }}),
     Prop("changing only the outer policy changes the outcome",
       fn () ->
         {
           let strict = sample(Bernoulli(0.5))
           let result =
             match strict {
               | True -> nested-refusal-world()
               | False -> nested-allowed-world()}
           match (strict, result) {
             | (True, Ok(((Err(ToolBlocked(_)), 0), _))) ->
               check.true(True, "strict policy refuses before action")
             | (False, Ok(((Ok(MkResponse(202, "live deployment accepted")), 4), _))) ->
               check.true(True, "permissive policy reaches four typed actions")
             | _ -> check.true(False, "policy-only outcome drift")
           }})])
