# archfit-action

Run [archfit](https://github.com/alexei-led/archfit) in CI and report the
architecture state it produced.

The analysis runs in **your** runner, not on our servers: archfit's facts come
from `go list`, dependency-cruiser, grimp, `cargo metadata`, ast-grep and jscpd,
so measuring your repository needs your toolchain and your private-dependency
credentials. This action carries the result out; it does not analyze anything
itself.

## Status

Early. The action assembles and writes the report envelope today. Sending it to
the archfit App is wired but the App backend is not generally available, so the
useful mode right now is the default one: **no `endpoint`, envelope written to a
file**, which also makes the report a normal build artifact you can inspect.

## Usage

```yaml
name: archfit
on: [pull_request, push]

jobs:
  architecture:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write          # only needed once `endpoint` is set
    container:
      image: ghcr.io/alexei-led/archfit:v2.2.1
      options: --user root     # the workspace is mounted as root
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0       # `--base` needs the base ref present

      - uses: actions/cache@v4
        with:
          path: .archfit-cache
          key: archfit-facts-${{ hashFiles('go.sum', 'package-lock.json', 'Cargo.lock') }}

      - name: Analyze
        run: archfit check --json -c .archfit.yaml > archfit-state.json || true

      - uses: alexei-led/archfit-action@v1
        with:
          state-file: archfit-state.json

      - uses: actions/upload-artifact@v4
        with:
          name: archfit-state
          path: |
            archfit-state.json
            archfit-envelope.json
```

Pin the analyzer image by digest rather than tag when you care about comparable
results over time: the analyzer version is part of what produced the facts.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `state-file` | `archfit-state.json` | The `archfit.architecture-state.v1` document to report. |
| `endpoint` | *(empty)* | App ingest URL. Empty means assemble the envelope and send nothing. |
| `envelope-file` | `archfit-envelope.json` | Where the envelope is written. |
| `audience` | `archfit-app` | OIDC audience, used only when `endpoint` is set. |

## Outputs

| Output | Meaning |
| --- | --- |
| `envelope-file` | Path of the written envelope. |
| `verdict` | `healthy`, `needs_attention` or `blocked`, as the document declares it. |

## What the envelope is, and is not

The envelope states **what was analysed**: repository, pull request, head SHA,
base SHA, merge base, and the report's digest. It reads those from the event
payload rather than from the job's own context, because a `workflow_run`
-triggered job runs the default branch's workflow definition and its
`GITHUB_SHA` is that context — not the pull request's.

It is **not** a security claim. Every field is self-reported by a job that runs
code from the pull request. The authoritative provenance — which workflow
definition ran, on which repository, at which attempt — lives in the OIDC
token's claims, which only the receiving service can verify. A report produced
by a job definition the pull request could edit can never satisfy a required
gate, however well-formed its envelope.

Fork pull requests cannot be granted `id-token: write` at all, so they have no
path to an authenticated upload. Treat their reports as advisory evidence.

## Requirements

`jq`, `curl` and `git` on PATH. The `ghcr.io/alexei-led/archfit` image ships
all three. The action refuses a document whose `schema_version` is not
`archfit.architecture-state.v1` rather than forwarding a shape the receiver
would have to guess at.

## License

Apache-2.0. See [LICENSE](LICENSE).
