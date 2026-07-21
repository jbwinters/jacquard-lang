workspace-why-effect-direct(policy, simulators) =
  workspace.live(policy, simulators, fn () -> (
    workspace.read-file(PathValue("README.md")),
    workspace.read-file(PathValue("README.md")),
    workspace.write-file(PathValue("review.txt"), "reviewed"),
    workspace.fetch(MkRequest("https://example.invalid", ""))))
