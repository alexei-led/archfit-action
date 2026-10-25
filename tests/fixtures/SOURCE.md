# Fixture provenance

The current `state.json`, `reanchored-baseline.json`, and `reanchor-report.txt`
were emitted unmodified by released Engine **v3.2.2**, source
`90c0ca240143329d404eb4eb116b096f607f7dc5`, using the synthetic Go repository
in `tests/engine-smoke.sh`.

- Native Linux arm64 Docker daemon (Colima on Apple Silicon).
- Platform image: `ghcr.io/alexei-led/archfit@sha256:e97a200a7c26907e4d30982b06e61ac7cc27bffd1d46002ad53bbf6b6594c479`.
- The updated Action was run through prepare, checkout, run and report. The
  capture uses a synthetic GitHub event and no upload endpoint. Its envelope is
  test evidence, not GitHub authentication or independently verified content.
- The native smoke validates report, baseline capture, comparable check,
  reanchor, legacy state-field removal and pull-request origin.
- Captures omit the unmeasured encapsulation reference but retain measured cycle zero.
- CI also runs the real image on native amd64 and arm64 runners. The captured
  state is replayed at process/network boundaries for transport/schema tests.

`stored-baseline.json` is the pre-existing v3.0.0 legacy baseline input. It is
not relabelled or regenerated; it retains the old fields the reanchor must drop.
`required-evidence/` retains its separately documented original producer inputs.
