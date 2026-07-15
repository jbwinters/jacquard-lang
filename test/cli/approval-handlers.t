ET.7's canonical handlers all revalidate the exact Proposal. Dry-run and an
already-Ask policy escalate, a scripted fixture may supply an explicit bound
Decision, and the console prints hash then authority before reading its answer.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > handlers.jac <<'EOF_JAC'
  > must-hash(text) = match hash.parse(text) {
  >   | Ok(value) -> value
  >   | Err(message) -> throw(message)
  > }
  >
  > proposal-value() = approval.make-proposal(
  >   must-hash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
  >   must-hash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
  >   must-hash("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
  >   [Effect("Net"), Resource("Net", "api.example")],
  >   quote { review("ship") },
  >   "ship?",
  >   None)
  >
  > throw.to-result(fn () -> {
  >   let proposal-value = proposal-value()
  >   let proposal-hash = approval.proposal-id(proposal-value)
  >   (
  >     approval.dry-run(fn () -> `op:ask`(proposal-value)),
  >     approval.policy-auto(fn () -> `op:ask`(proposal-value), fn (ignored) -> Ask),
  >     approval.scripted(
  >       fn () -> `op:ask`(proposal-value),
  >       [Approved(proposal-hash, "fixture", quote { ticket("ET.7") })]),
  >     approval.console(fn () -> `op:ask`(proposal-value))
  >   )
  > })
  > EOF_JAC

  $ printf 'approve\n' | jacquard run handlers.jac --allow console
  (approval-request-v1 (hash #edb1cedba2cdb7bd735ea27147b7ddf9891e4e145aff51b49337bca07f131993) (authority-list-v1 (effect-v1 (lit "Net")) (resource-v1 (lit "Net") (lit "api.example"))))
  ok((escalate(#edb1cedba2cdb7bd735ea27147b7ddf9891e4e145aff51b49337bca07f131993, "dry-run cannot consent"), escalate(#edb1cedba2cdb7bd735ea27147b7ddf9891e4e145aff51b49337bca07f131993, "policy-auto cannot upgrade Ask"), approved(#edb1cedba2cdb7bd735ea27147b7ddf9891e4e145aff51b49337bca07f131993, "fixture", (quote (app (var ticket) (lit "ET.7")))), approved(#edb1cedba2cdb7bd735ea27147b7ddf9891e4e145aff51b49337bca07f131993, "console", (quote (console-approval-v1 (lit "approve"))))))

The scripted handler fails closed when its explicit Decision list is exhausted.

  $ cat > exhausted.jac <<'EOF_JAC'
  > must-hash(text) = match hash.parse(text) {
  >   | Ok(value) -> value
  >   | Err(message) -> throw(message)
  > }
  >
  > proposal-value() = approval.make-proposal(
  >   must-hash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
  >   must-hash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
  >   must-hash("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
  >   [], quote { "ship" }, "ship?", None)
  >
  > throw.to-result(fn () -> {
  >   let proposal-value = proposal-value()
  >   approval.scripted(fn () -> `op:ask`(proposal-value), [])
  > })
  > EOF_JAC

  $ jacquard run exhausted.jac
  err("approval.scripted: out of scripted decisions")
