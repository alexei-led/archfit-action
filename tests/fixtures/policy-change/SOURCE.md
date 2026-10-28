# Policy-change fixtures

`widen.json`, `addrule.json` and `exclude.json` are `archfit config compare --json`
output (`archfit.config-compare.v1`) from the engine at commit
`feec08c3` (main, E11 merged as PR #110), built from source with `go build ./cmd/archfit`
and run on this repository's synthetic Go module (`pkg/a` imports `pkg/b`). Nothing
was edited. The branch build (873ddb1c) printed the same classification without the
`declarations_changed` list and the `supplied-coverage` entry, which the final shape adds.

- `base.yaml` is the current policy, `base-none.yaml` the same with `depends_on: []`
  for module `a`. `widen.candidate.yaml` widens `a`'s allowlist to `[b]`;
  `addrule.candidate.yaml` adds `no_direct_a_dependency`; `exclude.candidate.yaml`
  adds `exclude: [pkg/a/**]`.
- Command: `archfit config compare <candidate> -c <current> --root <repo> --json`,
  with the current file for `widen` being `base-none.yaml`.
- sha256:
  - `widen.json` 79a08107a657c97abb7f64127f9738321ff0b3f3578637c21bd818971f29a621
  - `addrule.json` bb069ce1c27741fae5a259a3cc57202b841ffd1fc4dbed9029a971f9e87feabf
  - `exclude.json` 91c51bce25d403a3d6495eb626c919f4d5aa3f10b6aae9031fee90af128a502e

Re-captured from the published v3.4.0 image (`ghcr.io/alexei-led/archfit@sha256:0cadc39c41de4dc58bb115b22bdd0296cb81688175a6ea1839a1e16ed2c35e1f`, linux/arm64) with the same command inside the container: the `policy_change` objects and the whole documents are byte-identical to the feec08c3 build, so the hashes above hold.
