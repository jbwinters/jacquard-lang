type GovernanceVersion = | GovernanceV0
type Hash = | HashValue(value: Text)
type Path = | PathValue(value: Text)
type AuditSequence = | AuditSequence(run-id: Hash)
type WorkspaceOperation = | ReadFileOperation | WriteFileOperation | FetchOperation
type SecretRef =
  | SecretRef(
      version: GovernanceVersion,
      name: Text,
      secret-version: Option Text)
type Secret = | OpaqueSecret

type Risk = | Low | Medium | High | Forbidden
type Verdict = | Allow | Simulate | Ask | Block
type ToolError =
  | Blocked(reason: Text)
  | Denied(reason: Text)
  | Escalated(reason: Text)
  | NoSimulation
  | DriverFailed(message: Text)
  | StaleApproval
  | InvalidDecision
type Authority =
  | Effect(effect-id: Hash)
  | Resource(effect-id: Hash, scope: Text, configuration: Hash)
type Call =
  | Call(
      version: GovernanceVersion,
      call-id: Hash,
      operation-id: Hash,
      operation-name: Text,
      arguments: Code,
      authority: List Authority,
      summary: Text,
      preconditions: Code,
      parent-call-id: Option Hash)
type Assessment =
  | Assessment(
      version: GovernanceVersion,
      risk: Risk,
      confidence: Real,
      reasons: List Text,
      evidence: Code)
type OutcomeSummary =
  | OutcomeSummary(
      version: GovernanceVersion,
      status: Text,
      digest: Hash,
      detail: Text)
type Proposal =
  | Proposal(
      version: GovernanceVersion,
      proposal-id: Hash,
      call-id: Hash,
      policy-id: Hash,
      assessment-id: Hash,
      rendering: Code,
      summary: Text,
      authority: List Authority,
      preview: Option OutcomeSummary)
type Decision =
  | Approved(proposal-id: Hash, approver: Text, evidence: Code)
  | Denied(proposal-id: Hash, approver: Text, reason: Text)
  | Escalate(proposal-id: Hash, reason: Text)
type AuditEntry =
  | Evaluated(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      policy-id: Hash,
      assessment: Assessment,
      verdict: Verdict)
  | Consented(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      proposal-id: Hash,
      decision: Decision)
  | Completed(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      branch: Text,
      outcome: OutcomeSummary)

type LivePolicy =
  | LivePolicy(
      version: GovernanceVersion,
      auto-up-to: Risk,
      ask-up-to: Risk,
      min-confidence: Real)
type DryPolicy =
  | DryPolicy(version: GovernanceVersion, min-confidence: Real)
type BoundPolicy a =
  | BoundPolicy(version: GovernanceVersion, policy-id: Hash, value: a)

once effect Judge where {
  judge.assess : (Call) -> Assessment
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
once effect Workspace where {
  workspace.read-file : (Path) -> Result ToolError Text
  workspace.write-file : (Path, Text) -> Result ToolError ()
  workspace.fetch : (Request) -> Result ToolError Response
}

fixture-hash = HashValue("fixture-v0")

operation-name-of(operation) = match operation {
  | ReadFileOperation -> "workspace.read-file"
  | WriteFileOperation -> "workspace.write-file"
  | FetchOperation -> "workspace.fetch"
}

call-id-for(operation) = HashValue(operation-name-of(operation))

authority-for(operation) = match operation {
  | ReadFileOperation -> [Effect(HashValue("effect:Fs"))]
  | WriteFileOperation -> [Effect(HashValue("effect:Fs"))]
  | FetchOperation ->
      [Effect(HashValue("effect:Net")), Effect(HashValue("effect:Secret"))]
}

call-for(operation) = {
  let operation-name = operation-name-of(operation)
  Call(
    GovernanceV0,
    call-id-for(operation),
    HashValue(operation-name),
    operation-name,
    quote {()},
    authority-for(operation),
    operation-name,
    quote {()},
    None)
}

proposal-for(operation) =
  Proposal(
    GovernanceV0,
    fixture-hash,
    call-id-for(operation),
    fixture-hash,
    fixture-hash,
    quote {()},
    "fixture proposal",
    authority-for(operation),
    None)

outcome-for(branch) =
  OutcomeSummary(GovernanceV0, branch, fixture-hash, "fixture outcome")

run-read-simulator : ((Path) ->{} Result ToolError Text, Path) ->{} Result ToolError Text
run-read-simulator(simulator, path) = simulator(path)

run-write-simulator : ((Path, Text) ->{} Result ToolError (), Path, Text) ->{} Result ToolError ()
run-write-simulator(simulator, path, text) = simulator(path, text)

run-fetch-simulator : ((Request) ->{} Result ToolError Response, Request) ->{} Result ToolError Response
run-fetch-simulator(simulator, request) = simulator(request)

next-sequence : (AuditSequence) ->{State} Int
next-sequence(owner) = match owner {
  | AuditSequence(_) -> {
      let sequence = get()
      put(add(sequence, 1))
      sequence
    }
}

agent() = {
  let first = workspace.read-file(PathValue("README.md"))
  let second = workspace.read-file(PathValue("docs/README.md"))
  match second { | _ -> first }
}

workspace.live-layer : (AuditSequence, BoundPolicy LivePolicy, Option ((Path) ->{} Result ToolError Text), Option ((Path, Text) ->{} Result ToolError ()), Option ((Request) ->{} Result ToolError Response)) ->{State, Judge, Approval, Audit, Fs, Net, Secret} Result ToolError Text
workspace.live-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator) =
  handle agent() {
    | return result -> result
    | workspace.read-file(path) resume continue -> {
        let request-call = call-for(ReadFileOperation)
        let request-id = call-id-for(ReadFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Ask))
        let decision = approval.ask(proposal-for(ReadFileOperation))
        let consented-sequence = next-sequence(sequence)
        audit.record(Consented(GovernanceV0, consented-sequence, request-id, fixture-hash, decision))
        let result = match path { | PathValue(raw) -> Ok(read(raw)) }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "live", outcome-for("live")))
        continue(result)
      }
    | workspace.write-file(path, text) resume continue -> {
        let request-call = call-for(WriteFileOperation)
        let request-id = call-id-for(WriteFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Ask))
        let decision = approval.ask(proposal-for(WriteFileOperation))
        let consented-sequence = next-sequence(sequence)
        audit.record(Consented(GovernanceV0, consented-sequence, request-id, fixture-hash, decision))
        let result = match path { | PathValue(raw) -> { write(raw, text); Ok(()) } }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "live", outcome-for("live")))
        continue(result)
      }
    | workspace.fetch(request) resume continue -> {
        let request-call = call-for(FetchOperation)
        let request-id = call-id-for(FetchOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Ask))
        let decision = approval.ask(proposal-for(FetchOperation))
        let consented-sequence = next-sequence(sequence)
        audit.record(Consented(GovernanceV0, consented-sequence, request-id, fixture-hash, decision))
        let secret = secret.read(SecretRef(GovernanceV0, "workspace", None))
        let exposed = secret.expose(secret)
        let result = match exposed { | _ -> Ok(fetch(request)) }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "live", outcome-for("live")))
        continue(result)
      }
  }

workspace.dry-layer : (AuditSequence, BoundPolicy DryPolicy, Option ((Path) ->{} Result ToolError Text), Option ((Path, Text) ->{} Result ToolError ()), Option ((Request) ->{} Result ToolError Response)) ->{State, Judge, Audit} Result ToolError Text
workspace.dry-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator) =
  handle agent() {
    | return result -> result
    | workspace.read-file(path) resume continue -> {
        let request-call = call-for(ReadFileOperation)
        let request-id = call-id-for(ReadFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Simulate))
        let result = match read-simulator {
          | None -> Err(NoSimulation)
          | Some(simulator) -> run-read-simulator(simulator, path)
        }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "simulated", outcome-for("simulated")))
        continue(result)
      }
    | workspace.write-file(path, text) resume continue -> {
        let request-call = call-for(WriteFileOperation)
        let request-id = call-id-for(WriteFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Simulate))
        let result = match write-simulator {
          | None -> Err(NoSimulation)
          | Some(simulator) -> run-write-simulator(simulator, path, text)
        }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "simulated", outcome-for("simulated")))
        continue(result)
      }
    | workspace.fetch(request) resume continue -> {
        let request-call = call-for(FetchOperation)
        let request-id = call-id-for(FetchOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Simulate))
        let result = match fetch-simulator {
          | None -> Err(NoSimulation)
          | Some(simulator) -> run-fetch-simulator(simulator, request)
        }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "simulated", outcome-for("simulated")))
        continue(result)
      }
  }

governance.with-sequence(body) = {
  let handled = state.run(fn () -> body(AuditSequence(fixture-hash)), 0)
  match handled { | (result, _) -> result }
}

workspace.live(policy, read-simulator, write-simulator, fetch-simulator) =
  governance.with-sequence(fn (sequence) ->
    workspace.live-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator))

workspace.dry-run(policy, read-simulator, write-simulator, fetch-simulator) =
  governance.with-sequence(fn (sequence) ->
    workspace.dry-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator))
