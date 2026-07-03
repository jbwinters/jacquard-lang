let cmd =
  let open Cmdliner in
  let doc = "The Weft language toolchain" in
  let info = Cmd.info "weft" ~version:Weft.Version.version ~doc in
  Cmd.v info Term.(const (fun () -> print_endline Weft.Version.version) $ const ())

let () = exit (Cmdliner.Cmd.eval cmd)
