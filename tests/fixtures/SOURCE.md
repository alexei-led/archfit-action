# Released-engine fixture provenance

`state.json`, `reanchored-baseline.json`, and `reanchor-report.txt` are unmodified
outputs captured on 2026-10-25 by `tests/engine-smoke.sh` from the released native
`linux/arm64` image:

- Engine: v3.2.0, source `faa4eb4e513859567fd6c380230c91ea22fdaab6`.
- Image: `ghcr.io/alexei-led/archfit@sha256:725c3a074358df8ea41881296eda06b07daed7934d7a6d40bb1ecfc3c8a8128d`.
- Publisher: [run40172977752](https://github.com/alexei-led/archfit/actions/runs/40172977752).
- Local invocation: `RUNNER_ARCH=ARM64 DOCKER_CONTEXT=colima ARCHFIT_FIXTURES_OUT=<output> bash tests/engine-smoke.sh`.

The script builds the scratch Go repository with `write_module`, then executes the
shipped prepare/run/report stages. `state.json` is the first blocked report.
The reanchor pair comes from the case that reads the historical `stored-baseline.json`.
No report JSON was edited to manufacture a positive result. The native smoke passed
31 assertions, including history, comparable capture/reanchor, and pull-request origin.
CI separately tests both native platforms. Local capture is not App approval.

| File | SHA-256 |
| --- | --- |
| `state.json` | `c472d77d04cf03d912d1a3f8b41e7494c9a688da60d957a71d789e05f07c5127` |
| `reanchored-baseline.json` | `0d347a5e7f8ec7f066ea517095f63cce54bf97c7a106e0c1b9bcd3115f7fe5e1` |
| `reanchor-report.txt` | `ac5ecbda6b0eca5f6b22fda277cc4e4fb79e285380bdc262ba399211bcdd2e04` |
| `stored-baseline.json` | `3cd0698b92e6a39ec2d1ea55733a19c58f2a51f294458f75991204c248b169dd` |

`stored-baseline.json` is unchanged historical v3.0.0 input. Its old fields and
stale accepted entry deliberately exercise reanchor migration. It is not a new
capture or a second supported engine. Report-stage evidence has its own [provenance](required-evidence/SOURCE.md).
