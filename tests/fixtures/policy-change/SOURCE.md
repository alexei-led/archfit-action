# Policy-change fixtures

`widen.json`, `addrule.json` and `exclude.json` are `archfit config compare --json`
output (`archfit.config-compare.v1`) from the engine at commit
`873ddb1c19350d2c42114f368deef3c40200e26a` (feat/agent-gate-e11, not yet on main),
built from source with `go build ./cmd/archfit` and run on this repository's
synthetic Go module (`pkg/a` imports `pkg/b`). Nothing was edited.

- `base.yaml` is the current policy, `base-none.yaml` the same with `depends_on: []`
  for module `a`. `widen.candidate.yaml` widens `a`'s allowlist to `[b]`;
  `addrule.candidate.yaml` adds `no_direct_a_dependency`; `exclude.candidate.yaml`
  adds `exclude: [pkg/a/**]`.
- Command: `archfit config compare <candidate> -c <current> --root <repo> --json`,
  with the current file for `widen` being `base-none.yaml`.
- sha256:
  - `widen.json` 9aea3e86b3f328b25f5bbbd2d3c0b426fe61b3525b0a22685cc115d54667bd59
  - `addrule.json` d4e571f062391133f00b778afae7d5df68463760bb453f1e74b40d92f770a43c
  - `exclude.json` 5ff02496dfb96ca4a5bead12e68257b0dfccffc337abcb9ad7883c27a1aff373

Re-capture from the engine's merged v3.4.0 image before the release, and update the
hashes here.
