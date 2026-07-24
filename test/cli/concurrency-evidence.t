SC.16 runs one checked task program under all four shipped C2 scheduler seams.
The checker output proves that spawning keeps Async and the child's Net effect,
while async.scope removes only Async. The exhaustive tree has exactly eight
complete, unique, replayable schedules.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ JACQUARD=jac sh ../../demos/concurrency/run.sh
  == child authority stays visible ==
  spawn-net : () ->{Async, Net} Task Text
  scoped-net : () ->{Net} TaskResult (TaskResult Text)
  == one task program, four scheduler handlers ==
  program-hash=0c6c2bb245f0fd38e47abfd04313156954f74e7a1ca2eb4d0ca553c93ce1098a
  trace-format=1
  round-robin scheduler=fifo-round-robin-v0 result=0 tasks=3 decisions=5 trace=13b32f8467e9d40e38117f9d46ca47e6ab9665fe68272efa8a9082c63aab94a8
  seeded scheduler=seeded-random-v0 seed=20260717 result=0 tasks=3 decisions=5 trace=f911e0e95e08a9b1c1e312381a7f8c6ae6d07101d1e2e9a4ddfecf0216044327
  exhaustive completeness=complete explored=8 worlds-started=8 unique-traces=8 all-zero=true
  replay source=round-robin result=0 byte-identical=true
  exhaustive-replay worlds=8 byte-identical=true

SC.17 keeps the historical SC.16 attestation intact and adds a separately
reconstructible correction pack for transitive cancellation of nested runs.
The Dune sandbox pins the retained manifest and checker bytes without applying
their historical inventories to the moving source tree. The production
history gate reconstructs and executes each checker at its registered
publication commit.

  $ sha256sum \
  >   ../../docs/release/structured-concurrency/MANIFEST.sha256 \
  >   ../../scripts/release/check-structured-concurrency-manifest.sh \
  >   ../../docs/release/governed-membranes/GM21-MANIFEST.sha256 \
  >   ../../scripts/release/check-gm21-manifest.sh \
  >   ../../docs/release/structured-concurrency/SC17-MANIFEST.sha256 \
  >   ../../scripts/release/check-sc17-manifest.sh
  3ca69edb0121713deb211042dfe2099bbd425c05292789d46a5db00e4d52ffd9  ../../docs/release/structured-concurrency/MANIFEST.sha256
  d0b40d94343a06343f08dbcf2a11c7b11fcf8a465df4e3375b4bfd703b62a495  ../../scripts/release/check-structured-concurrency-manifest.sh
  19603651590eb6de890a7e3597b009403f03234d6d5f022b076497d8a638e45f  ../../docs/release/governed-membranes/GM21-MANIFEST.sha256
  14fcc2ec9274d1dde793ef534591c4d757934089d0510424e52187e9b0fd5a82  ../../scripts/release/check-gm21-manifest.sh
  dd597d01e8d806fa8d962db419ca23ecb16031989526dd3ee01b130567eb6c50  ../../docs/release/structured-concurrency/SC17-MANIFEST.sha256
  4e35e42c06b251d9caefb34970f7d66cd5aca58c4f4caaa342efb20045e036ae  ../../scripts/release/check-sc17-manifest.sh
