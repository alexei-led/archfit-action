# Fixture provenance

These files are the unchanged results emitted by the first published archfit
`v4.0.0` image, source commit `37dd38244081ad1159c27515cec94560f3e44e30`. They were
captured from that `linux/amd64` per-platform image
`ghcr.io/alexei-led/archfit@sha256:3edf066717390ef79f8ae42974c62ccbd93a5bb6b9bc571cbf1dcf9c9ae0fc26`.

`v4.0.0` was published again from source commit `9715378a421af060962f737ed6aaf6096c26f57b`
([release run 43741387062](https://github.com/alexei-led/archfit/actions/runs/43741387062))
when the Go module moved to `/v4`; the engine code and this result contract did not
change, so these five files were not re-captured. The pinned-image smoke job runs the
current image through the same scenarios, and the Action's pinned digests name it:
`linux/amd64` is `sha256:be1eac8f73513c6d0ef4ff17a78255629e4e4bc2d1b3e044b49afcbfdd6aac29`.
The rebuild details are in [image-identity.json](https://github.com/alexei-led/archfit/releases/download/v4.0.0/image-identity.json).

The `Pinned engine image (linux/amd64)` job in [Action CI run 43696615582](https://github.com/alexei-led/archfit-action/actions/runs/43696615582)
ran `bash tests/engine-smoke.sh` with `ARCHFIT_FIXTURES_OUT` set, then uploaded
`engine-fixtures-amd64`. That script builds the scratch repositories and captures
these five scenarios. The image version is `v4.0.0`; each result names `4.0.0`.
The same run passed the smoke test on `linux/arm64` using its own image digest.
The engine release was published by [release run 43695907192](https://github.com/alexei-led/archfit/actions/runs/43695907192).

| File | SHA-256 |
| --- | --- |
| `result/eol-differs.json` | `8d622af3dcad988b46782dd0eed9b90cc82734562d7b87310ccef07f81299e29` |
| `result/fail.json` | `098b3e62f1a4dfc11917156ca601405b427a32f244144d73b573392ea61536dc` |
| `result/pass.json` | `6f5903f068ac42384920738d454dbba5cc00576554ca5adae40df86b5aa85223` |
| `result/policy-differs.json` | `a49716d231e7b36c0e6981496a1a10f6f44dfe1cf20ddc2c2c9df818fd3ab5bc` |
| `result/push-at-tip.json` | `b45d4d22e77f4e5b71c86a746c2f0fa85403b4d97e3397752094b860f4c4c1ea` |
