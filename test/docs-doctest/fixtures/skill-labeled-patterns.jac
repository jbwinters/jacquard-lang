type Snapshot =
  | Snapshot(id: Int, error: Int, vendor: Text)

describe(snap) =
  match snap {
    | Snapshot(vendor: vendor, error: problem) -> (problem, vendor)
  }
