-- Deterministic interpreters for the unchanged agent in agent.jac.
type AgentFaultPlan =
  | AgentFaultPlan(manifest-read-fails: Bool, artifact-fetch-fails: Bool, config-write-fails: Bool,
                   deployment-fetch-fails: Bool)

demo-assessment =
  GovernanceAssessmentV0(GovernanceV0, Medium, 0.9, ["flagship fixture"],
    quote { flagship-assessment })

demo-simulators =
  workspace.simulators(Some(fn (_) -> Ok("release=v18")), Some(fn (_, _) -> Ok(())),
    Some(
      fn (request) ->
        match request {
          | MkRequest("https://artifacts.example/release", _) ->
            Ok(MkResponse(200, "sha256:artifact-v18"))
          | MkRequest("https://deploy.example/apply", _) ->
            Ok(MkResponse(202, "dry deployment accepted"))
          | _ -> Err(DriverFailed("unexpected URL"))}))

bind-dry-policy() =
  match governance.make-dry-policy(0.5) {
    | Err(message) -> throw(message)
    | Ok(policy) ->
      match governance.bind-dry-policy(policy) {
        | Err(message) -> throw(message)
        | Ok(bound) -> bound}}

bind-live-policy(auto-up-to, ask-up-to) =
  match governance.make-live-policy(auto-up-to, ask-up-to, 0.5) {
    | Err(message) -> throw(message)
    | Ok(policy) ->
      match governance.bind-live-policy(policy) {
        | Err(message) -> throw(message)
        | Ok(bound) -> bound}}

-- No grant and no raw effect handler exist in this world. The simulator
-- bundle is statically pure, so all four Workspace operations are simulated.
dry-world() =
  throw.to-result(
    fn () ->
      judge.fixed(
        fn () ->
          audit.in-memory(
            fn () ->
              workspace.dry-run(bind-dry-policy(), demo-simulators,
                fn () -> governed-deploy-agent())), demo-assessment))

-- The immutable plan is selected by fault.all before this Workspace Once
-- handler is installed. Each failure returns without resuming, so the tuple is
-- the exact facade-call prefix reached by the unchanged agent.
run-agent-fault-plan(plan) =
  match plan {
    | AgentFaultPlan(manifest-fails, artifact-fails, write-fails, deployment-fails) ->
      (handle governed-deploy-agent() {
         | return result ->
           fn (reads, artifact-fetches, writes, deployment-fetches) ->
             (plan, result, reads, artifact-fetches, writes, deployment-fetches)
         | workspace.read-file(PathValue("deploy/manifest.json")) resume continue ->
           fn (reads, artifact-fetches, writes, deployment-fetches) ->
             match manifest-fails {
               | True -> {
                 let failure = Err(DriverFailed("manifest read injected"))
                 let next = add(reads, 1)
                 (plan, failure, next, artifact-fetches, writes, deployment-fetches)
               }
               | False -> {
                 let next = add(reads, 1)
                 continue(Ok("release=v18"))(next, artifact-fetches, writes, deployment-fetches)
               }}
         | workspace.write-file(PathValue("generated/deploy.conf"),
           "artifact=sha256:artifact-v18") resume continue ->
           fn (reads, artifact-fetches, writes, deployment-fetches) ->
             match write-fails {
               | True ->
                 (plan, Err(DriverFailed("config write injected")), reads, artifact-fetches,
                  add(writes, 1), deployment-fetches)
               | False -> {
                 let next = add(writes, 1)
                 continue(Ok(()))(reads, artifact-fetches, next, deployment-fetches)
               }}
         | workspace.fetch(request) resume continue ->
           fn (reads, artifact-fetches, writes, deployment-fetches) ->
             match request {
               | MkRequest("https://artifacts.example/release", "release=v18") ->
                 match artifact-fails {
                   | True ->
                     (plan, Err(DriverFailed("artifact fetch injected")), reads,
                      add(artifact-fetches, 1), writes, deployment-fetches)
                   | False -> {
                     let next = add(artifact-fetches, 1)
                     continue(Ok(MkResponse(200, "sha256:artifact-v18")))(reads, next, writes,
                       deployment-fetches)
                   }}
               | MkRequest("https://deploy.example/apply", "artifact=sha256:artifact-v18") ->
                 match deployment-fails {
                   | True ->
                     (plan, Err(DriverFailed("deployment fetch injected")), reads,
                      artifact-fetches, writes, add(deployment-fetches, 1))
                   | False -> {
                     let next = add(deployment-fetches, 1)
                     continue(Ok(MkResponse(202, "live deployment accepted")))(reads,
                       artifact-fetches, writes, next)
                   }}
               | _ ->
                 (plan, Err(DriverFailed("unexpected fault-world request")), reads,
                  artifact-fetches, writes, deployment-fetches)}})(0, 0, 0, 0)}

agent-fault-world() =
  throw.to-result(
    fn () ->
      fault.all(
        fn () ->
          {
            let plan =
              AgentFaultPlan(flaky("manifest.read"), flaky("artifact.fetch"),
                flaky("config.write"), flaky("deployment.fetch"))
            run-agent-fault-plan(plan)}, 32))

agent-fault-trace-valid?(trace) =
  match trace {
    | (AgentFaultPlan(True, _, _, _), Err(DriverFailed("manifest read injected")), 1, 0, 0, 0) ->
      True
    | (AgentFaultPlan(False, True, _, _), Err(DriverFailed("artifact fetch injected")), 1, 1, 0, 0) ->
      True
    | (AgentFaultPlan(False, False, True, _), Err(DriverFailed("config write injected")), 1, 1, 1,
       0) -> True
    | (AgentFaultPlan(False, False, False, True), Err(DriverFailed("deployment fetch injected")),
       1, 1, 1, 1) -> True
    | (AgentFaultPlan(False, False, False, False), Ok(MkResponse(202, "live deployment accepted")),
       1, 1, 1, 1) -> True
    | _ -> False}

agent-fault-healthy?(trace) =
  match trace {
    | (AgentFaultPlan(False, False, False, False), Ok(MkResponse(202, _)), 1, 1, 1, 1) -> True
    | _ -> False}

agent-fault-row() =
  {
    let report =
      test.run(
        fn () ->
          match agent-fault-world() {
            | Ok(traces) -> {
              let all-valid =
                list.fold(traces, True,
                  fn (valid, trace) -> bool.and(valid, agent-fault-trace-valid?(trace)))
              let healthy =
                list.fold(traces, 0,
                  fn (count, trace) ->
                    match agent-fault-healthy?(trace) {
                      | True -> add(count, 1)
                      | False -> count})
              check.true(
                match (all-valid, list.length(traces), healthy) {
                  | (True, 16, 1) -> True
                  | _ -> False}, "gm18-agent-fault-prefixes")
            }
            | Err(_) -> check.true(False, "gm18-agent-fault-prefixes")})
    match report {
      | MkReport(Cons(("gm18-agent-fault-prefixes", True), Nil), None) ->
        ("agent/fault-all", "all-prefixes-valid", "paths", 16, "prefixes",
         "manifest:8/artifact:4/write:2/deployment:1/healthy:1", "healthy", 1, "failing", 15,
         "deployment-max", 1)
      | _ ->
        ("agent/fault-all", "unexpected", "paths", 0, "prefixes", "unexpected", "healthy", 0,
         "failing", 0, "deployment-max", 0)
    }}

-- This counter is outside the governed body and counts only a raw Workspace
-- action that survives every nested policy. The stricter outer policy blocks
-- the very first call, so the handler is never reached.
with-raw-workspace-counter(body) =
  (handle body() {
     | return value -> fn (count) -> (value, count)
     | workspace.read-file(_) resume continue ->
       fn (count) -> {
                       let next = add(count, 1)
                       continue(Ok("release=v18"))(next)}
     | workspace.write-file(_, _) resume continue ->
       fn (count) -> {
                       let next = add(count, 1)
                       continue(Ok(()))(next)}
     | workspace.fetch(request) resume continue ->
       fn (count) ->
         {
           let next = add(count, 1)
           let response =
             match request {
               | MkRequest("https://artifacts.example/release", _) ->
                 MkResponse(200, "sha256:artifact-v18")
               | MkRequest("https://deploy.example/apply", _) ->
                 MkResponse(202, "live deployment accepted")
               | _ -> MkResponse(500, "unexpected raw fetch")}
           continue(Ok(response))(next)}})(0)

-- This defensive handler closes the static Approval row. The chosen policies
-- never reach it: Medium is allowed by the inner policy and blocked by the
-- outer policy. If that premise drifts, it still fails closed.
with-unexpected-approval-denied(body) =
  handle body() {
    | return value -> value
    | governance-approval.ask(proposal-value) resume continue ->
      continue(
        Denied(governance.proposal-id(proposal-value), "demo-invariant",
          "unexpected approval request"))}

nested-world-with(agent, outer-auto-up-to, outer-ask-up-to) =
  throw.to-result(
    fn () ->
      judge.fixed(
        fn () ->
          audit.in-memory(
            fn () ->
              with-unexpected-approval-denied(
                fn () ->
                  governance.with-sequence(
                    fn (sequence) ->
                      with-raw-workspace-counter(
                        fn () ->
                          workspace.forward-layer(sequence,
                            bind-live-policy(outer-auto-up-to, outer-ask-up-to), demo-simulators,
                            fn () ->
                              workspace.forward-layer(sequence, bind-live-policy(Medium, High),
                                demo-simulators, fn () -> agent())))))), demo-assessment))

nested-world(outer-auto-up-to, outer-ask-up-to) =
  nested-world-with(fn () -> governed-deploy-agent(), outer-auto-up-to, outer-ask-up-to)

nested-refusal-world() = nested-world(Low, Low)

nested-allowed-world() = nested-world(Medium, High)

policy-diff-worlds() =
  throw.to-result(
    fn () ->
      {
        let agent = fn () -> governed-deploy-agent()
        let strict-policy = bind-live-policy(Low, Low)
        let permissive-policy = bind-live-policy(Medium, High)
        (governance.bound-policy-id(strict-policy), governance.bound-policy-id(permissive-policy),
         nested-world-with(agent, Low, Low), nested-world-with(agent, Medium, High), False)})

-- Actual live composition: the inner membrane retains only Workspace and
-- forwards into the released raw-driver leaf. The remaining Fs/Net/Secret row
-- is deliberately visible and is installed by the checkout evidence host.
-- Judge also stays visible here so a durable approval host can assess the
-- exact released Call without changing the agent or membrane composition.
live-approval-world(outer-auto-up-to, outer-ask-up-to) =
  throw.to-result(
    fn () ->
      audit.in-memory(
        fn () ->
          governance.with-sequence(
            fn (sequence) ->
              workspace.live-layer(sequence, bind-live-policy(outer-auto-up-to, outer-ask-up-to),
                demo-simulators,
                fn () ->
                  workspace.forward-layer(sequence, bind-live-policy(Medium, High),
                    demo-simulators, fn () -> governed-deploy-agent())))))

live-world(outer-auto-up-to, outer-ask-up-to) =
  with-unexpected-approval-denied(
    fn () ->
      throw.catch(
        fn () ->
          judge.fixed(fn () -> live-approval-world(outer-auto-up-to, outer-ask-up-to),
            demo-assessment), fn (message) -> Err(message)))

identity-row-of(call, policy, proposal-value) =
  (hash.to-text(governance.call-id(call)), hash.to-text(governance.bound-policy-id(policy)),
   hash.to-text(governance.proposal-id(proposal-value)))

-- Identity rows are derived from the released constructors used by the
-- running membrane. They are data, not copied constants.
identity-row() =
  {
    let request = MkRequest("https://deploy.example/apply", "artifact=sha256:artifact-v18")
    let call =
      match workspace.call-fetch(request) {
        | Err(message) -> throw(message)
        | Ok(value) -> value}
    let policy = bind-live-policy(Medium, High)
    let proposal-result =
      governance.make-proposal(call, policy, demo-assessment, governance.call-code(call),
        governance.call-summary(call), None)
    let proposal-value =
      match proposal-result {
        | Err(message) -> throw(message)
        | Ok(value) -> value}
    identity-row-of(call, policy, proposal-value)}

deployment-proposal-for(request) =
  {
    let call =
      match workspace.call-fetch(request) {
        | Err(message) -> throw(message)
        | Ok(value) -> value}
    let policy = bind-live-policy(Medium, High)
    let proposal-result =
      governance.make-proposal(call, policy, demo-assessment, governance.call-code(call),
        governance.call-summary(call), None)
    match proposal-result {
      | Err(message) -> throw(message)
      | Ok(proposal-value) -> proposal-value
    }}

deployment-proposal() =
  deployment-proposal-for(
    MkRequest("https://deploy.example/apply", "artifact=sha256:artifact-v18"))

-- Durable approval is a proposal-only preflight boundary. The trusted host may
-- separately orchestrate a live phase after Approved; this expression never
-- enters live-world, so bridge reruns cannot replay Fs, Net, or Secret work.
deployment-approval-request() =
  throw.catch(
    fn () ->
      {
        let proposal-value = deployment-proposal()
        let decision = governance-approval.ask(proposal-value)
        match governance.approval.validate-decision(proposal-value, decision) {
          | Ok(exact-decision) -> Ok(exact-decision)
          | Err(message) -> Err(DriverFailed(message))
        }}, fn (message) -> Err(DriverFailed(message)))

dry-row() =
  match dry-world() {
    | Ok((Ok(MkResponse(status, _)), entries)) ->
      ("agent/dry", "simulated", status, list.length(entries), "raw-actions", 0)
    | _ -> ("agent/dry", "unexpected", 0, 0, "raw-actions", 0)}

nested-row(label, run) =
  match run() {
    | Ok(((Err(ToolBlocked(_)), raw-actions), entries)) ->
      (label, "refused", list.length(entries), "raw-actions", raw-actions)
    | Ok(((Ok(MkResponse(_, _)), raw-actions), entries)) ->
      (label, "allowed", list.length(entries), "raw-actions", raw-actions)
    | _ -> (label, "unexpected", 0, "raw-actions", 0)}

-- --- demo driver ---
dry-row()

("call-id/policy-id/proposal-id", throw.to-result(fn () -> identity-row()))

agent-fault-row()
