(** RW.8 behavior review: two checked versions of an entry compared over declared finite or sampled
    cases under an observation policy (docs/behavior-review.md). *)

val diagnostic : code:string -> string -> Diag.t
(** [diagnostic ~code cause] is a review refusal: [code] is one of E1010–E1015
    ([Bug_invalid_diagnostic] otherwise). *)

type options = {
  prelude_dir : string;
  old_file : string;
  old_source : string;
  new_file : string;
  new_source : string;
  cases_file : string;
  cases_source : string;
  entry : string;
  domains : string list;  (** one cases-file domain term per entry parameter, in order *)
  fields : string list;  (** pure derived-field terms over the entry's arguments *)
  adapter : string option;  (** a new-version term with the old entry's contract *)
  handles : (string * string) list;  (** (operation name, pure model term) *)
  wrap : string option;  (** a cases-file handler term wrapped around each case *)
  policy : Observation_policy.t;
  fuel : int;  (** each version's aggregate run fuel, and each preparation allowance *)
  max_cases : int;  (** cases run; later cases are unrun *)
  sample : (int * int) option;  (** (count, seed) *)
  only_case : int option;  (** run only this case *)
}

(** {1 Cases and grouping} *)

val decode : int list -> int -> int list
(** [decode sizes n] is case [n]'s element index per parameter for domains of [sizes], the first
    parameter outermost. *)

type element = {
  value : Value.t;
  observed : Observation.value;
  data : string;  (** full data-v1 rendering *)
  weight : float option;  (** a distribution element's weight *)
}

val merge_support : element list -> element list
(** [merge_support elements] merges equal data at the first position (weights summed) and drops
    zero-weight elements, keeping declaration order. Every element must carry a weight. *)

val sample_indices : element list list -> count:int -> seed:int -> int list list
(** [sample_indices domains ~count ~seed] draws [count] cases: with
    [root = Infer_dist.Rng.make seed], parameter k's stream is the (k+1)-th
    [Infer_dist.Rng.split root], and case i's index for parameter k is the (i+1)-th
    [Infer_dist.draw] from that stream over domain k's weights. *)

type kind = Decision | Effect | Failure_kind
type verdict = Agree | Differ of kind | Inconclusive | Both_failed | Unrun
type atom = { path : string; head : string }

val value_atoms : string -> Observation.value -> atom list
(** [value_atoms root value] is the preorder [path=head] atoms of [value]: constructors by identity,
    children [.0], [.1], ... by position, tuples as [tuple/<arity>], literals by data-v1. *)

type group = {
  group_kind : kind;
  members : int list;  (** case numbers, ascending *)
  condition : [ `Atoms of atom list | `All | `Ungrouped ];
}

val groups : atoms_of:(int -> atom list) -> verdicts:(int * verdict) list -> group list
(** [groups ~atoms_of ~verdicts] partitions the differing cases by kind (decision, effect, failure)
    and gives each part an exact conjunction: the atoms all members share, greedily reduced in
    canonical order while no agreeing case satisfies the remainder; [`All] when nothing remains,
    [`Ungrouped] when the shared atoms already match an agreeing case. Deterministic. *)

(** {1 Reviews} *)

type review

val run : options -> (review, Diag.t list) result
(** [run options] checks both versions with the cases file and a generated driver in private scratch
    stores, refuses an invalid request (E1010–E1015, E1005) before any case runs, then runs every
    case in each version under the policy with the modeled root operations and compares the paired
    one-run transcripts. *)

val serialize : review -> string
(** The canonical [behavior-review-report] format 1 data, including the request bytes. *)

val render : review -> string
(** The readable report: counts, scope, grouped differences with witnesses, and the claim. *)

val exit_status : review -> int
(** 0 when every declared case ran and agreed, 1 when a case differs, 2 otherwise. *)
