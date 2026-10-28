# Fixture provenance

The current `state.json`, `reanchored-baseline.json`, and `reanchor-report.txt`
were emitted unmodified by released Engine **v3.4.0**, source
`2692cd6b8aab23e559d0aa76712a192d69b4229f`, using the synthetic Go repository
in `tests/engine-smoke.sh` (`ARCHFIT_FIXTURES_OUT`).

- Native Linux arm64 Docker daemon (Colima on Apple Silicon).
- Platform image: `ghcr.io/alexei-led/archfit@sha256:0cadc39c41de4dc58bb115b22bdd0296cb81688175a6ea1839a1e16ed2c35e1f` (linux/arm64; index `sha256:e4c258d0698c223cca223568a9fec1cd5393937cc6e6ce58def1f62b66205dd4`).
- The image reports `archfit version v3.4.0 (commit 2692cd6, built 2026-10-28T18:42:58Z)`.
- The Action ran through prepare, checkout, run and report with synthetic GitHub
  events and no upload endpoint. Its envelope is test evidence, not GitHub
  authentication or independently verified report content.
- Native smoke passed all 33 assertions: report, actual stored-baseline capture,
  comparable check, reanchor, legacy state-field removal and pull-request origin.
- Captures omit the unmeasured encapsulation reference but retain measured cycle zero.
- `reanchor-report.txt` is byte-identical to the v3.2.3 capture. `state.json` and
  `reanchored-baseline.json` differ from it only where v3.4.0 adds to the contract:
  the top-level `identity` block, a `supplied-coverage` measurement-profile producer,
  and the `dotnet-msbuild`, `roslyn` and `supplied-coverage` coverage tools. Nothing
  was relabeled or tailored.

| File | SHA-256 |
| --- | --- |
| `state.json` | `958a3de5c00bd41d8221a58381c6f30653ba1ae114f285ec34401954509c5d34` |
| `reanchored-baseline.json` | `ea073aa8eb5b6f9c8e16a4571d6e2ca10e40b74dc711c60a6083f8f4f763737f` |
| `reanchor-report.txt` | `9150a14a515ac840b0b6cd851a89dee49e65e4d80bcb8395c6e484f7d0fd6f38` |

The same smoke recipe exports a fresh `captured-baseline.json` and `envelope.json`
when `ARCHFIT_FIXTURES_OUT` is set. The fresh stored baseline's SHA-256 is
`08e1b5572046781772d87b584325edcc24188b08afbeecf08adff1b15768981d`.
These are qualification artifacts, not manufactured transport fixtures.

To reproduce on an existing native arm64 `colima` context, use a new owned output
directory under its existing HOME share. The script's supported `TMPDIR` must
also be visible to the daemon:

```sh
capture="$HOME/archfit-action-v2.2.1-capture"
test ! -e "$capture"
mkdir -p "$capture/tmp"
DOCKER_CONTEXT=colima RUNNER_ARCH=ARM64 TMPDIR="$capture/tmp" \
  ARCHFIT_FIXTURES_OUT="$capture/outputs" bash tests/engine-smoke.sh
```

CI runs the real image on native amd64 and arm64 runners and preserves the
exported artifacts. App admission and approved consumer tuples remain separate
gates.

`stored-baseline.json` is the pre-existing v3.0.0 legacy baseline input. It is
not relabeled or regenerated; it retains the old fields the reanchor must drop.
Its SHA-256 remains
`3cd0698b92e6a39ec2d1ea55733a19c58f2a51f294458f75991204c248b169dd`.
`required-evidence/` retains its separately documented original producer inputs.
