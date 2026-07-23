open Jacquard
module D = Governance_decision_chain

let fixtures =
  [
    ("allowed.json", D.Allow_fixture);
    ("blocked.json", D.Block_fixture);
    ("stale-approval.json", D.Stale_approval_fixture);
    ("transformed.json", D.Transformed_call_fixture);
    ("attempt-missing-completion.json", D.Missing_completion_fixture);
    ("dry-simulation.json", D.Dry_simulation_fixture);
  ]

let write path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel (contents ^ "\n"))

let () =
  let output =
    match Sys.getenv_opt "JACQUARD_GOVERNANCE_PLAYGROUND_FIXTURES_OUT" with
    | Some path -> path
    | None -> "playground/governance/fixtures/generated"
  in
  if not (Sys.file_exists output) then Unix.mkdir output 0o755;
  List.iter
    (fun (name, scenario) ->
      write (Filename.concat output name) (D.fixture scenario |> D.render_json_v1))
    fixtures
