# Reproducing Jacquard Core 0.3

The release is reproduced from Git history. An exported source directory
without the repository's full history cannot satisfy the historical
publication gate.

## Candidate Reproduction

```sh
git clone https://github.com/jbwinters/jacquard-lang.git
cd jacquard-lang
git checkout <candidate-commit>

asdf install
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"

JACQUARD_RELEASE_REF=HEAD \
JACQUARD_RELEASE_BASE=f296ec1333072a1bdddb53f707eef836926cdb43 \
  scripts/release/reproduce-0.3.sh
```

The script records the full commit ID in `.scratch/release/0.3/commit.txt` and
writes command transcripts under `.scratch/release/0.3/transcripts/`. It may
install missing opam dependencies into the repository-local switch.

## What Runs

The script verifies historical manifests, the 0.2 manifest at the
`jacquard-core-0.2.0` tag, that `docs/release/0.2/` still equals its published
bytes, and the complete 0.3 diff manifest, then runs:

- `dune build @all`, `dune build @doc`, the full test suite, 36 doctests, and
  the depth-100,000 parser guard;
- the GM.12B 50,000-case evidence target;
- runtime memory, native differential, leak, and 1,000-case seeded fuzz lanes
  independently under Clang and GCC;
- formatting cleanliness, exact `0.3.0` version output, packaging, installer,
  checksum, and installed-demo smoke;
- the public demo set, including structured concurrency, governed Workspace,
  and Night Shift;
- release-focused cram transcripts, including local projects and bundles,
  the host worker, fuel, inference outcomes, observation policies, scoped
  instances, opaque types and the abstract-types and everyday-application
  demos, and the compiled `gauntlet-.*` selection.

GitHub's `Release Evidence / Reproduce 0.3 evidence` workflow runs the same
script for release branches, `jacquard-core-*` tags, and manual dispatch, then
uploads both this documentation directory and generated transcripts.

## RC and Final Promotion

1. Merge the release PR after every required protected-branch context passes.
2. Manually reproduce release evidence for the exact merge commit.
3. Create `jacquard-core-0.3.0-rc1` on that commit.
4. Require both tag-triggered release-evidence and release-binary workflows to
   pass. Verify all three archives and three checksum assets, and smoke the
   public installer with `JACQUARD_INSTALL_VERSION` set to the RC tag.
5. If no code or documentation changes are needed, create
   `jacquard-core-0.3.0` on the same commit. Do not rebuild a different source
   revision merely to remove the prerelease suffix.
6. Verify the final tag's evidence, archives, checksums, installer default,
   and public release metadata before announcement.

If RC verification finds a defect, fix it through a new reviewed release PR
and use a new RC tag. Never move a published tag.
