(** Pure deterministic input derivation shared by relational execution lanes. *)

module Int_set = Set.Make (Int)

let secret_redaction_marker = "<secret redacted>"

(** [schedule_seeds] keeps the root seed as run one and rejects duplicate SplitMix64 candidates so
    every accepted constituent schedule has a distinct seed. *)
let schedule_seeds ~root_seed ~count =
  if count <= 0 then []
  else
    let generator = Infer_dist.Rng.make root_seed in
    let rec accept remaining seen reversed =
      if remaining = 0 then List.rev reversed
      else
        let candidate = Int64.to_int (Infer_dist.Rng.next_int64 generator) in
        if Int_set.mem candidate seen then accept remaining seen reversed
        else accept (remaining - 1) (Int_set.add candidate seen) (candidate :: reversed)
    in
    accept (count - 1) (Int_set.singleton root_seed) [ root_seed ]

(** [secret_payloads] derives two printable, visibly tool-owned payloads from the existing
    SplitMix64 stream. The lane labels keep the payloads distinct even if the two generator outputs
    were ever equal. *)
let secret_payloads ~root_seed =
  let generator = Infer_dist.Rng.make root_seed in
  let first = Infer_dist.Rng.next_int64 generator in
  let second = Infer_dist.Rng.next_int64 generator in
  (Printf.sprintf "rw-secret-v0-a-%016Lx" first, Printf.sprintf "rw-secret-v0-b-%016Lx" second)

let starts_with_at source ~offset needle =
  let source_length = String.length source in
  let needle_length = String.length needle in
  if offset + needle_length > source_length then false
  else
    let rec equal index =
      index = needle_length || (source.[offset + index] = needle.[index] && equal (index + 1))
    in
    equal 0

(** [redact] scans raw bytes before any diagnostic escaping. Longer payloads win at an overlapping
    position so replacing a prefix cannot expose the suffix of another forbidden payload. *)
let redact ~secrets source =
  let secrets =
    secrets
    |> List.filter (fun secret -> not (String.equal secret ""))
    |> List.sort_uniq String.compare
    |> List.sort (fun left right -> Int.compare (String.length right) (String.length left))
  in
  match secrets with
  | [] -> source
  | _ ->
      let buffer = Buffer.create (String.length source) in
      let rec scan offset =
        if offset = String.length source then Buffer.contents buffer
        else
          match List.find_opt (starts_with_at source ~offset) secrets with
          | Some secret ->
              Buffer.add_string buffer secret_redaction_marker;
              scan (offset + String.length secret)
          | None ->
              Buffer.add_char buffer source.[offset];
              scan (offset + 1)
      in
      scan 0
