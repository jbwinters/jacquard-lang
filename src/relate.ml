(** Pure deterministic input derivation shared by relational execution lanes. *)

module Int_set = Set.Make (Int)

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
