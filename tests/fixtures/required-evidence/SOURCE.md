# Required-evidence report-stage fixtures

Both files are unmodified `archfit.architecture-state.v1` outputs from the released
v3.2.0 image, source `faa4eb4e513859567fd6c380230c91ea22fdaab6`:
`ghcr.io/alexei-led/archfit@sha256:725c3a074358df8ea41881296eda06b07daed7934d7a6d40bb1ecfc3c8a8128d` (`linux/arm64`).

They were copied from the `release-image-contract-ubuntu-24.04-arm` artifact in
[publisher run40172977752](https://github.com/alexei-led/archfit/actions/runs/40172977752).
That artifact's `version.txt`, `image.json`, and per-case `command.json` record the
producer and invocations. No candidate capture was relabeled or JSON tailored.
The reports happen to be byte-identical to the earlier candidate regressions.

| File | Original path under `contracts/` | SHA-256 |
| --- | --- | --- |
| `missing-compiler.json` | `compiler-negative/check.json` | `acde9deda04172707184b6f61c10ee866ecc166aa4c94fb8f2e57f6b7274cce7` |
| `optional-attention.json` | `go-65532/reanchored.json` | `5200d5bcf764fcfed75fd427cae7720a67ff361824b4d134850112c5d11715e6` |

The missing-compiler case mounts an empty read-only TypeScript compiler directory.
Its required import rule is unevaluated and hard gates are unmeasured.
The optional-attention report follows a real capture/reanchor. Hard gates pass,
no blockers or required gaps remain, and four dimensions are unknown.
The producer omits the empty `unevaluated_required_rules` field.

Tests replay these bytes only through the shipped report stage. Facts/envelopes
are synthetic transport wrappers, not executed identity or App approval proof.
Malformed and contradictory mutations are negative tests, never engine captures.
Full conformance uses the separate genuine release [state capture](../SOURCE.md).
