# Required-evidence report-stage fixtures

These are **unmodified engine outputs**, not hand-written positive states. Both
use `archfit.architecture-state.v1` and came from the local, unreleased candidate
`11e84d1152d96ca724ac27326932ff8a689a6439`, image
`sha256:c206455444ebae08fad47b2b3a4ff503e8b466f615bc4cf8a2a3c6d954302714`
(`archfit-upgrade-image:integrated-11e84d11`, `linux/arm64`). This is **not** an
admitted or released v3.0.1 producer, nor a new supported-engine pin.

Capture root:
`archfit-tool-upgrade-lab/2026-10-24-release/validation-image-arm64/contracts-integrated-11e84d11/`
in the release coordinator's workspace. Its `image.json` records the local image;
each case's `command.json` records the invocation.

| Fixture                   | Original path under capture root | SHA-256                                                            |
| ------------------------- | -------------------------------- | ------------------------------------------------------------------ |
| `missing-compiler.json`   | `compiler-negative/check.json`   | `acde9deda04172707184b6f61c10ee866ecc166aa4c94fb8f2e57f6b7274cce7` |
| `optional-attention.json` | `go-65532/reanchored.json`       | `5200d5bcf764fcfed75fd427cae7720a67ff361824b4d134850112c5d11715e6` |

The missing-compiler case ran as uid/gid `27182:27182`, with an empty read-only
mount over `/opt/archfit/analyzers/node/node_modules/typescript`. It ran
`archfit check --root /tmp/repo --config /tmp/repo/.archfit.yaml --json --quiet --refresh`
and exited 2. The report records the dependency-cruiser compiler failure,
`hard_gates: unmeasured`, and an unevaluated required rule.

The optional-attention case ran as uid/gid `65532:65532`. After a genuine baseline
capture and re-anchor in the same image, it ran
`archfit check --root /tmp/repo --config /tmp/repo/.archfit.yaml --json --quiet`
and exited 2. Its hard gates pass, there are no active blockers or unevaluated
required rules, and four dimensions remain unknown. The producer omits the
empty `unevaluated_required_rules` field (`omitempty`).

Both captures used read-only trusted fixtures, a scratch `/tmp/repo`, no network,
no-new-privileges, and all capabilities dropped. The regression tests replay
these bytes **only through the shipped report stage**. Their facts/envelope
wrapper is synthetic test transport metadata, not evidence that this Action
executed or admitted that image. Deliberate malformed/contradictory test mutations
are named as such and are not engine captures. Full legacy Action conformance
continues to use the separate pinned v3.0.1 `ARCHFIT_TEST_STATE` document.
