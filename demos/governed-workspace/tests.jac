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
     Case("fault.all covers every governed agent failure prefix",
       fn () ->
         match agent-fault-world() {
           | Ok(traces) -> {
             let all-valid =
               list.fold(traces, True,
                 fn (valid, trace) -> bool.and(valid, agent-fault-trace-valid?(trace)))
             let prefixes =
               list.fold(traces, (0, 0, 0, 0, 0),
                 fn (counts, trace) ->
                   match (counts, trace) {
                     | ((manifest, artifact, write, deployment, healthy),
                        (AgentFaultPlan(True, _, _, _), _, _, _, _, _)) ->
                       (add(manifest, 1), artifact, write, deployment, healthy)
                     | ((manifest, artifact, write, deployment, healthy),
                        (AgentFaultPlan(False, True, _, _), _, _, _, _, _)) ->
                       (manifest, add(artifact, 1), write, deployment, healthy)
                     | ((manifest, artifact, write, deployment, healthy),
                        (AgentFaultPlan(False, False, True, _), _, _, _, _, _)) ->
                       (manifest, artifact, add(write, 1), deployment, healthy)
                     | ((manifest, artifact, write, deployment, healthy),
                        (AgentFaultPlan(False, False, False, True), _, _, _, _, _)) ->
                       (manifest, artifact, write, add(deployment, 1), healthy)
                     | ((manifest, artifact, write, deployment, healthy),
                        (AgentFaultPlan(False, False, False, False), _, _, _, _, _)) ->
                       (manifest, artifact, write, deployment, add(healthy, 1))})
             check.eq(list.length(traces), 16, int.eq, int.show, "2^4 immutable plans")
             check.true(all-valid,
               "failure halts the exact prefix, earlier failures skip deployment, deployment <= 1")
             match prefixes {
               | (8, 4, 2, 1, 1) ->
                 check.true(True, "manifest/artifact/write/deployment/healthy prefixes")
               | _ -> check.true(False, "fault prefix coverage drifted")
             }
           }
           | Err(_) -> check.true(False, "fault.all refused bounded four-site world")}),
     Prop("changing only the outer policy changes the outcome",
       fn () ->
         {
           let strict = sample(Bernoulli(0.5))
           match policy-diff-worlds() {
             | Ok((strict-policy-id, permissive-policy-id, strict-result, permissive-result,
                   agent-changed)) -> {
               check.true(bool.not(governance.hash-eq?(strict-policy-id, permissive-policy-id)),
                 "semantic policy IDs differ")
               check.true(bool.not(agent-changed),
                 "one unchanged agent binding serves both policy worlds")
               let result = match strict {
                              | True -> strict-result
                              | False -> permissive-result}
               match (strict, result) {
                 | (True, Ok(((Err(ToolBlocked(_)), 0), _))) ->
                   check.true(True, "strict policy refuses before action")
                 | (False, Ok(((Ok(MkResponse(202, "live deployment accepted")), 4), _))) ->
                   check.true(True, "permissive policy reaches four typed actions")
                 | _ -> check.true(False, "policy-only outcome drift")
               }
             }
             | _ -> check.true(False, "policy identity or fixed-agent evidence drifted")
           }})])
