# Fixture provenance

The current `state.json`, `reanchored-baseline.json`, and `reanchor-report.txt`
were emitted unmodified by released Engine **v3.2.3**, source
`c7490636480a8faedddf3bff1d0a678a7ab7987c`, using the synthetic Go repository
in `tests/engine-smoke.sh`.

- Native Linux arm64 Docker daemon (Colima on Apple Silicon).
- Platform image: `ghcr.io/alexei-led/archfit@sha256:54f6bf1ec99be6f4bdc21ca59e16d3dd65fb5b31a2c2af6c932ad556c89a220c`.
- The image reports `archfit version v3.2.3 (commit c749063, built 2026-10-26T11:51:31Z)`.
- The Action ran through prepare, checkout, run and report with synthetic GitHub
  events and no upload endpoint. Its envelope is test evidence, not GitHub
  authentication or independently verified report content.
- Native smoke passed all 33 assertions: report, actual stored-baseline capture,
  comparable check, reanchor, legacy state-field removal and pull-request origin.
- Captures omit the unmeasured encapsulation reference but retain measured cycle zero.
- These three outputs are byte-identical to the earlier genuine v3.2.2 captures.
  Their new provenance was verified by executing the real published v3.2.3 image,
  not by relabeling or tailoring JSON. Their measurement profile and fact-input
  hashes also match the prior capture exactly.

| File | SHA-256 |
| --- | --- |
| `state.json` | `c472d77d04cf03d912d1a3f8b41e7494c9a688da60d957a71d789e05f07c5127` |
| `reanchored-baseline.json` | `254496115e437d0f7d32f7273626a808596152556d40b0edfb24bb9ee848a88f` |
| `reanchor-report.txt` | `9150a14a515ac840b0b6cd851a89dee49e65e4d80bcb8395c6e484f7d0fd6f38` |

The same smoke recipe exports a fresh `captured-baseline.json` and `envelope.json`
when `ARCHFIT_FIXTURES_OUT` is set. The fresh stored baseline's SHA-256 is
`8dd2d79aefa9852cbf6bfbcd20b6b38e666d83986d66f464f9e142a2a260418e`.
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
