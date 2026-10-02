type t = int

(* process-wide, so two scopes never share a token across contexts, runs or domains *)
let counter = Atomic.make 0
let fresh () = Atomic.fetch_and_add counter 1 + 1
let same = Int.equal
