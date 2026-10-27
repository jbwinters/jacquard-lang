ask-name() = {
  println("name?")
  match next-line() {
    | Some(name) -> println($"hello {name}")
    | None -> println("no input")
  }
}

status-of(url) =
  match fetch(MkRequest(url: url, body: "")) {
    | MkResponse(status: status) -> status
  }

token() = secret.expose(secret.read(SecretRef(name: "deploy-token", version: None)))
