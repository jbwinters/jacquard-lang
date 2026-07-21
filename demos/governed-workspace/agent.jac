write-config-and-deploy : (Text) ->{Workspace} Result ToolError Response
write-config-and-deploy(generated) =
  match workspace.write-file(PathValue("generated/deploy.conf"), generated) {
    | Err(error) -> Err(error)
    | Ok(_) -> workspace.fetch(MkRequest("https://deploy.example/apply", generated))}

fetch-artifact : (Text) ->{Workspace} Result ToolError Response
fetch-artifact(manifest) =
  match workspace.fetch(MkRequest("https://artifacts.example/release", manifest)) {
    | Err(error) -> Err(error)
    | Ok(MkResponse(_, artifact)) -> write-config-and-deploy(text.concat("artifact=", artifact))}

-- The application stays unchanged across dry-run, nested governance, and live
-- execution. It knows only the released Workspace facade: even deployment is
-- an ordinary typed Request passed to workspace.fetch.
governed-deploy-agent : () ->{Workspace} Result ToolError Response
governed-deploy-agent() =
  match workspace.read-file(PathValue("deploy/manifest.json")) {
    | Err(error) -> Err(error)
    | Ok(manifest) -> fetch-artifact(manifest)}
