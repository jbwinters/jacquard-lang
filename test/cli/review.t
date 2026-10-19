Behavior review (RW.8): two checked versions of an entry compared over
declared finite cases (docs/behavior-review.md).

  $ export JACQUARD_PRELUDE=$PWD/../../prelude

The scheduling example of docs/designs/behavioral-change-review.md §6. The new
policy holds a low-priority job when only one worker is up.

  $ cat > old.jac <<'JACQUARD'
  > type Worker = | W1 | W2 | W3
  > type State = | Up | Down
  > type Availability = | Availability(w1: State, w2: State, w3: State)
  > type Priority = | High | Low
  > type Assignment = | Dispatch Worker | Hold | Queue
  > 
  > up?(a, w) = match w {
  >   | W1 -> match availability.w1(a) { | Up -> True | Down -> False }
  >   | W2 -> match availability.w2(a) { | Up -> True | Down -> False }
  >   | W3 -> match availability.w3(a) { | Up -> True | Down -> False }
  > }
  > 
  > available(a) = list.filter([W1, W2, W3], fn (w) -> up?(a, w))
  > 
  > assign : (Priority, Availability) ->{} Assignment
  > assign(job, a) = match available(a) {
  >   | Nil -> Queue
  >   | Cons(w, _) -> Dispatch(w)
  > }
  > JACQUARD
  $ sed 's/^  | Nil -> Queue$/  | Nil -> Queue\n  | Cons(w, Nil) -> match job { | High -> Dispatch(w) | Low -> Hold }/' old.jac > new.jac
  $ cat > cases.jac <<'JACQUARD'
  > priorities = [High, Low]
  > availabilities = [
  >   Availability(Up, Up, Up), Availability(Up, Up, Down),
  >   Availability(Up, Down, Up), Availability(Up, Down, Down),
  >   Availability(Down, Up, Up), Availability(Down, Up, Down),
  >   Availability(Down, Down, Up), Availability(Down, Down, Down)]
  > count-up(job, a) = list.length(available(a))
  > JACQUARD

Cases are the product of the domains, the first parameter outermost. The
condition is an exact conjunction over declared fields, and the witness is the
first differing case: `Low` with only W1 up is case 11, the 12th of 16.

  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priorities --domain availabilities --field count-up -o report.txt > report.out; echo "exit=$?"
  exit=1
  $ sed 1d report.out
    old old.jac, new new.jac, entry assign
    policy a9e4cff5d4dd7a3176a3a77a6ce702b85a224f49b7deb7af171f46e88f505afc
  Status exhaustive-complete, on the 16 declared cases.
    16 run: 13 agree, 3 differ, 0 inconclusive, 0 failed in both, 0 unrun.
  
  3 cases differ (decision):
    when arg0 = low and count-up = 1
    witness case 11 (12 of 16): low, availability(up, down, down)
      old: dispatch(w1)
      new: hold
  
  This review covers only the declared cases. It does not show that the versions are
  equivalent anywhere else.

The report data is deterministic: the same request writes the same bytes.

  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priorities --domain availabilities --field count-up -o again.txt > /dev/null; echo "exit=$?"
  exit=1
  $ cmp report.txt again.txt && echo identical
  identical
  $ sed -n '/^status/,/^witness/p' report.txt
  status exhaustive-complete mode exhaustive
  counts cases=16 agree=13 differ=3 inconclusive=0 failed=0 unrun=0
  group index=0 kind=decision cases=3 first=11 condition=2
  atom path=arg0 value bytes=68
  low#896ad3f49db0360fbfd9a2d397dcd505865f10555c0c695d4067330763479650
  atom field=count-up value bytes=1
  1
  witness case=11

Witness replay: `--case 11` runs only that case, and its two run transcripts are
the report's witness blocks byte for byte.

  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priorities --domain availabilities --case 11 -o case11.txt > case11.out; echo "exit=$?"
  exit=1
  $ sed -n 4,5p case11.out
  Status exhaustive-complete, on the one selected case.
    1 run: 0 agree, 1 differ, 0 inconclusive, 0 failed in both, 0 unrun.
  $ sed -n '/^old bytes/,$p' report.txt | sed -n '/^old bytes/,/^case /p' | sed '$d' > witness.blocks
  $ sed -n '/^old bytes/,$p' case11.txt | sed -n '/^old bytes/,/^case /p' | sed '$d' > replay.blocks
  $ cmp witness.blocks replay.blocks && echo replayed
  replayed

Versions that agree on every declared case exit 0, and the claim keeps its
scope.

  $ jacquard review run --old old.jac --new old.jac --cases cases.jac --entry assign --domain priorities --domain availabilities > same.out; echo "exit=$?"
  exit=0
  $ sed -n '4,5p;7p' same.out
  Status exhaustive-complete, on the 16 declared cases.
    16 run: 16 agree, 0 differ, 0 inconclusive, 0 failed in both, 0 unrun.
  The versions agree on the 16 declared cases.

A run budget leaves the remainder unrun: the review is incomplete, never
called agreement.

  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priorities --domain availabilities --max-cases 10 -o bounded.txt > bounded.out; echo "exit=$?"
  exit=2
  $ sed -n 4,5p bounded.out
  Status exhaustive-incomplete, on the 16 declared cases.
    10 run: 10 agree, 0 differ, 0 inconclusive, 0 failed in both, 6 unrun.
  $ grep '^case index' bounded.txt
  case index=10 to=15 verdict=unrun old=not-started new=not-started

Sampling draws from Distribution domains with a seed and says so: a rare
difference can be missed, and agreement is only "in N sampled cases".

  $ cat >> cases.jac <<'JACQUARD'
  > priority-model = Categorical([MkPair(High, 0.5), MkPair(Low, 0.5)])
  > availability-model = Categorical([
  >   MkPair(Availability(Up, Up, Up), 0.729), MkPair(Availability(Up, Up, Down), 0.081),
  >   MkPair(Availability(Up, Down, Up), 0.081), MkPair(Availability(Up, Down, Down), 0.009),
  >   MkPair(Availability(Down, Up, Up), 0.081), MkPair(Availability(Down, Up, Down), 0.009),
  >   MkPair(Availability(Down, Down, Up), 0.009), MkPair(Availability(Down, Down, Down), 0.001)])
  > JACQUARD
  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priority-model --domain availability-model --sample 100 --seed 7 > sampled.out; echo "exit=$?"
  exit=0
  $ sed -n '4,5p;7p' sampled.out
  Status sampled, in 100 sampled cases (seed 7).
    100 run: 100 agree, 0 differ, 0 inconclusive, 0 failed in both, 0 unrun.
  The versions agree in 100 sampled cases (seed 7).
  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priority-model --domain availability-model --field count-up > exact.out; echo "exit=$?"
  exit=1
  $ sed -n '4,5p;8p' exact.out
  Status exhaustive-complete, on the 16 declared cases.
    16 run: 13 agree, 3 differ, 0 inconclusive, 0 failed in both, 0 unrun.
    when arg0 = low and count-up = 1
  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priorities --domain availabilities --sample 5 --seed 7; echo "exit=$?"
  error[E1015]: A behavior review's sampling options are invalid
    Cause: --sample needs every domain to be a Distribution
    Next step: Pass --sample N with --seed S, sample only Distribution domains, keep N within --max-cases.
  exit=3
  $ jacquard review run --old old.jac --new new.jac --cases cases.jac --entry assign --domain priority-model --domain availability-model --sample 5; echo "exit=$?"
  error[E1015]: A behavior review's sampling options are invalid
    Cause: --sample and --seed must be given together
    Next step: Pass --sample N with --seed S, sample only Distribution domains, keep N within --max-cases.
  exit=3

Entry contracts: a reordered signature is refused unless a named adapter with
the old entry's contract stands in for the new entry.

  $ sed 's/^assign : (Priority, Availability) ->{} Assignment$/assign : (Availability, Priority) ->{} Assignment/; s/^assign(job, a) = /assign(a, job) = /' new.jac > swapped.jac
  $ jacquard review run --old old.jac --new swapped.jac --cases cases.jac --entry assign --domain priorities --domain availabilities > swapped.out 2>&1; echo "exit=$?"
  exit=3
  $ sed 's/#[0-9a-f]\{64\}/#H/g' swapped.out
  error[E1011]: The two versions' entry contracts differ
    Cause: the old entry has signature (#H, #H) ->{} #H labels positional; the new entry has (#H, #H) ->{} #H labels positional
    Next step: Compare entries with one signature and call labels, or name an --adapter.
  $ printf 'assign-compat : (Priority, Availability) ->{} Assignment\nassign-compat(job, a) = assign(a, job)\n' >> swapped.jac
  $ jacquard review run --old old.jac --new swapped.jac --cases cases.jac --entry assign --adapter assign-compat --domain priorities --domain availabilities > adapted.out; echo "exit=$?"
  exit=1
  $ sed -n '2p;5p' adapted.out
    old old.jac, new swapped.jac, entry assign (adapter assign-compat)
    16 run: 13 agree, 3 differ, 0 inconclusive, 0 failed in both, 0 unrun.

Effects: operations the entry performs are modeled at the root by pure terms,
so the policy observes them. Equal results with different effects are an
effect difference; an unmodeled operation is a missing world.

  $ cat > notify-old.jac <<'JACQUARD'
  > once effect Notify where {
  >   notify : (Text) -> ()
  > }
  > 
  > route : (Int) ->{Notify} Int
  > route(n) = {
  >   notify("routed")
  >   n
  > }
  > JACQUARD
  $ sed 's/notify("routed")/notify("queued")/' notify-old.jac > notify-new.jac
  $ printf 'sizes = [1, 2]\nack(t) = ()\nquiet(thunk) = handle thunk() { | return v -> v | notify(t) resume k -> k(()) }\n' > notify-cases.jac
  $ jacquard review run --old notify-old.jac --new notify-new.jac --cases notify-cases.jac --entry route --domain sizes --handle notify=ack -o effects.txt > effects.out; echo "exit=$?"
  exit=1
  $ sed -n 5,11p effects.out
    2 run: 0 agree, 2 differ, 0 inconclusive, 0 failed in both, 0 unrun.
  
  2 cases differ (effect):
    in every analyzed case (no case agrees)
    witness case 0 (1 of 2): 1
      old: 1 (1 observed operation)
      new: 1 (1 observed operation)
  $ grep -c '^event index=0' effects.txt
  2
  $ jacquard review run --old notify-old.jac --new notify-new.jac --cases notify-cases.jac --entry route --domain sizes; echo "exit=$?"
  error[E1012]: A behavior review's domain, field or world is invalid
    Cause: missing world configuration: the old entry performs effects that no --handle models
    Next step: Declare each domain as a finite List or Distribution of the parameter's type, keep fields and handlers pure, and --handle every operation the entry performs.
  exit=3

A wrap handles the operation inside the case, where the root never sees it.

  $ jacquard review run --old notify-old.jac --new notify-new.jac --cases notify-cases.jac --entry route --domain sizes --wrap quiet > wrapped.out; echo "exit=$?"
  exit=0
  $ sed -n 5p wrapped.out
    2 run: 2 agree, 0 differ, 0 inconclusive, 0 failed in both, 0 unrun.

Failures are findings, attributed per version.

  $ printf 'limits = [1, 2, 3]\nscale : (Int) ->{} Int\nscale(n) = div(12, n)\n' > scale-old.jac
  $ sed 's/div(12, n)/div(12, sub(n, 2))/' scale-old.jac > scale-new.jac
  $ printf 'probe = limits\n' > scale-cases.jac
  $ jacquard review run --old scale-old.jac --new scale-new.jac --cases scale-cases.jac --entry scale --domain probe -o failure.txt > failure.out; echo "exit=$?"
  exit=1
  $ sed -n 4p failure.out
  Status failed, on the 3 declared cases.
  $ grep '^case index' failure.txt
  case index=0 verdict=differ:decision old=complete new=complete
  case index=1 verdict=differ:failure old=complete new=failed:uncoded
  case index=2 verdict=differ:decision old=complete new=complete

Refusals happen before anything runs (exit 3): domains that differ between
versions, a cases file that redeclares a version name, and a pinned policy.

  $ sed 's/limits = \[1, 2, 3\]/limits = [1, 0, 3]/' scale-new.jac > scale-other.jac
  $ jacquard review run --old scale-old.jac --new scale-other.jac --cases scale-cases.jac --entry scale --domain probe; echo "exit=$?"
  error[E1013]: The two versions' review domains differ
    Cause: the two versions' domain values differ
    Next step: Declare the same domain values in both versions, over unchanged types.
  exit=3
  $ printf 'limits = [4]\n' > clash-cases.jac
  $ jacquard review run --old scale-old.jac --new scale-new.jac --cases clash-cases.jac --entry scale --domain limits > clash.out 2>&1; echo "exit=$?"
  exit=3
  $ head -2 clash.out
  error[E1010]: A behavior review's program or cases file is invalid
    Cause: the old version does not check together with the cases file
  $ printf 'jacquard-observation-policy format=1\nresult=compare field-bytes=4096 interface=%064d\nunlisted=record arguments=all result=ignore output=compare\noperations=0\n' 0 > pinned.policy
  $ jacquard review run --old scale-old.jac --new scale-new.jac --cases scale-cases.jac --entry scale --domain probe --policy pinned.policy > pinned.out 2>&1; echo "exit=$?"
  exit=3
  $ head -2 pinned.out
  error[E1014]: The observation policy cannot apply to both versions
    Cause: the policy is pinned to an interface; a review compares two versions, whose manifests differ
