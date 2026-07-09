(** Entry-point contract for the recovering `.jac` parser.

    [recover_string] always returns the partial surface tree plus diagnostics. [parse_string] is the
    strict command/build boundary: it succeeds only when recovery produced no errors or holes. The
    parser implementation lands in SS.5-SS.15; this scaffold deliberately does not claim to parse
    `.jac` yet. *)

let unavailable ~file =
  Diag.error ~code:"E1200" (Printf.sprintf "surface parser for %s is not implemented yet" file)

(** [kernel_name_of_pascal] is the parser/resolver's D34 boundary for ordinary uppercase names.
    Kind-tagged escapes instead use {!Surface_name.decode_escaped}. *)
let kernel_name_of_pascal surface = Surface_name.of_pascal surface

let recover_string ~file src : Surface_ast.recovered =
  if String.trim src = "" then { items = []; diagnostics = [] }
  else { items = []; diagnostics = [ unavailable ~file ] }

(** [strict recovered] rejects parser errors and any partial tree containing a recovery hole. This
    is the boundary that prevents holes from reaching lowering, canonicalization, or execution. *)
let strict (recovered : Surface_ast.recovered) : (Surface_ast.top list, Diag.t list) result =
  let errors =
    List.filter (fun d -> d.Diag.severity = Diag.Error) recovered.Surface_ast.diagnostics
  in
  if errors <> [] then Error recovered.diagnostics
  else if List.exists Surface_ast.has_holes_top recovered.items then
    Error
      [
        Diag.error ~code:"E1202"
          "surface parser recovery left holes; fix the syntax before checking or hashing";
      ]
  else Ok recovered.items

(** [parse_string ~file src] strictly parses a complete surface file. It returns every top-level
    item in document order, or diagnostics when syntax recovery was required. *)
let parse_string ~file src : (Surface_ast.top list, Diag.t list) result =
  strict (recover_string ~file src)
