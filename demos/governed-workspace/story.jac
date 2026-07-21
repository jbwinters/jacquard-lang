-- Deterministic interpreters for the unchanged agent in agent.jac.
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

nested-world(outer-auto-up-to, outer-ask-up-to) =
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
                                demo-simulators, fn () -> governed-deploy-agent())))))),
        demo-assessment))

nested-refusal-world() = nested-world(Low, Low)

nested-allowed-world() = nested-world(Medium, High)

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
    let policy = bind-live-policy(Low, High)
    let proposal-result =
      governance.make-proposal(call, policy, demo-assessment, governance.call-code(call),
        governance.call-summary(call), None)
    let proposal-value =
      match proposal-result {
        | Err(message) -> throw(message)
        | Ok(value) -> value}
    identity-row-of(call, policy, proposal-value)}

deployment-proposal() =
  {
    let request = MkRequest("https://deploy.example/apply", "artifact=sha256:artifact-v18")
    let call =
      match workspace.call-fetch(request) {
        | Err(message) -> throw(message)
        | Ok(value) -> value}
    let policy = bind-live-policy(Low, High)
    let proposal-result =
      governance.make-proposal(call, policy, demo-assessment, governance.call-code(call),
        governance.call-summary(call), None)
    match proposal-result {
      | Err(message) -> throw(message)
      | Ok(proposal-value) -> proposal-value
    }}

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

nested-row("agent/live-nested/strict-outer", fn () -> nested-refusal-world())

nested-row("agent/live-nested/permissive-outer", fn () -> nested-allowed-world())

("call-id/policy-id/proposal-id", throw.to-result(fn () -> identity-row()))
