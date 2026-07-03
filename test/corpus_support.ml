(** Shared plumbing for corpus-driven tests and the golden generator: the deterministic stub name
    environment (until W2.6's real prelude replaces it), file IO, and the full
    parse-validate-resolve-hash pipeline. *)

open Weft

(* Deterministic fake globals: hash of "stub:<name>". Regenerate the golden hashes when the
   real prelude replaces this environment. *)
let stub_hash name = Hash.of_string ("stub:" ^ name)

let stub_entries =
  List.map
    (fun (n, k) -> (n, { Resolve.hash = stub_hash n; kind = k }))
    [
      ("add", Resolve.KTerm);
      ("sub", Resolve.KTerm);
      ("mul", Resolve.KTerm);
      ("div", Resolve.KTerm);
      ("eq", Resolve.KTerm);
      ("body", Resolve.KTerm);
      ("true", Resolve.KCon);
      ("false", Resolve.KCon);
      ("some", Resolve.KCon);
      ("none", Resolve.KCon);
      ("abort", Resolve.KOp);
      ("print", Resolve.KOp);
      ("int", Resolve.KType);
      ("text", Resolve.KType);
      ("option", Resolve.KType);
      ("console", Resolve.KEffect);
      ("net", Resolve.KEffect);
    ]

let stub_names = Resolve.of_alist stub_entries

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let wft_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".wft")
  |> List.sort String.compare

(** Pipeline stages, in order; invalid corpus cases name the stage they must die at. *)
type stage = Parse | Validate | Resolve | Hashing

let stage_name = function
  | Parse -> "parse"
  | Validate -> "validate"
  | Resolve -> "resolve"
  | Hashing -> "hash"

let stage_of_name = function
  | "parse" -> Some Parse
  | "validate" -> Some Validate
  | "resolve" -> Some Resolve
  | "hash" -> Some Hashing
  | _ -> None

(** Run the full pipeline on one source string, reporting which stage failed. *)
let staged_pipeline ~file src : (Canon.decl_hashes list, stage * Diag.t list) result =
  match Reader.parse_string ~file src with
  | Error ds -> Error (Parse, ds)
  | Ok forms ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | f :: rest -> (
            match Kernel.of_form f with
            | Error ds -> Error (Validate, ds)
            | Ok top -> (
                match Resolve.resolve stub_names top with
                | Error ds -> Error (Resolve, ds)
                | Ok resolved -> (
                    match Canon.hash_top resolved with
                    | Error ds -> Error (Hashing, ds)
                    | Ok hs -> go (hs :: acc) rest)))
      in
      go [] forms

(** [staged_pipeline] with the stage dropped. *)
let pipeline ~file src : (Canon.decl_hashes list, Diag.t list) result =
  Result.map_error snd (staged_pipeline ~file src)

(** Parse a corpus [.expect] sidecar: line 1 [stage: <parse|validate|resolve|hash>], line 2
    [code: E0xxx]. *)
let parse_expect src : (stage * string) option =
  let strip s = String.trim s in
  match String.split_on_char '\n' src |> List.map strip |> List.filter (fun l -> l <> "") with
  | [ stage_line; code_line ]
    when String.length stage_line > 6
         && String.sub stage_line 0 6 = "stage:"
         && String.length code_line > 5
         && String.sub code_line 0 5 = "code:" ->
      let stage = strip (String.sub stage_line 6 (String.length stage_line - 6)) in
      let code = strip (String.sub code_line 5 (String.length code_line - 5)) in
      Option.map (fun s -> (s, code)) (stage_of_name stage)
  | _ -> None

(** Golden lines for one file: [file:idx <hex>] for each top form, plus [file:idx:name <hex>] for
    each named hash. Sorted output is stable. *)
let golden_lines ~file src : (string list, Diag.t list) result =
  Result.map
    (fun hashes ->
      List.concat
        (List.mapi
           (fun i { Canon.decl_hash; named } ->
             Printf.sprintf "%s:%d %s" file i (Hash.to_hex decl_hash)
             :: List.map (fun (n, h) -> Printf.sprintf "%s:%d:%s %s" file i n (Hash.to_hex h)) named)
           hashes))
    (pipeline ~file src)

let corpus_golden_lines ~valid_dir =
  List.concat_map
    (fun file ->
      match golden_lines ~file (read_file (Filename.concat valid_dir file)) with
      | Ok lines -> lines
      | Error ds ->
          failwith
            (Printf.sprintf "%s failed the pipeline: %s" file
               (String.concat "; " (List.map Diag.to_string ds))))
    (wft_files valid_dir)
