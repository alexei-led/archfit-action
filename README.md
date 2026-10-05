# archfit-action

Run [archfit](https://github.com/alexei-led/archfit) in CI and report the
architecture state to the archfit GitHub App.

The analysis runs in **your** runner, inside the pinned engine image. The action
checks out the commit, gives the engine the policy, baseline and labels from the
protected ref, runs the image, and sends the report with an OIDC-authenticated
upload. Nothing is analyzed on archfit's servers.

## Usage

The archfit App generates this workflow during onboarding. It pins the action by
commit and the engine image by digest:

```yaml
name: archfit
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      discover:
        description: Propose a policy for review instead of reporting state
        type: boolean
        default: false

permissions:
  contents: read
  id-token: write

jobs:
  archfit:
    runs-on: ubuntu-latest
    steps:
      - uses: alexei-led/archfit-action@<40-hex commit>
        with:
          endpoint: "https://<archfit App>"
          audience: "https://<archfit App>"
          engine-version: "v2.3.1"
          image-digest: "sha256:7d4f73248865e11bbfe244cd477bd0ea8e8cbdc0b7fb2baade8e044b618b2793"
          discover: ${{ inputs.discover }}
```

Do not add a checkout step: the action does its own, without persisted
credentials.

Without `endpoint` the action analyzes only: nothing is sent, the report or the
captured baseline is a workflow artifact, and a `blocked` verdict fails the job. No App checks that a
policy owner approved a pull request's change to the policy, baseline or labels,
so a pull request is measured against the base branch's files only. Its own
edits to them have no effect, and a pull request that deletes `.archfit.yaml`
fails.

`endpoint` is the App base URL over `https`, without a trailing slash. Plain
`http` is accepted only for `127.0.0.1` and `localhost`.

The action runs on `pull_request`, `push` and `workflow_dispatch` only. It
refuses `workflow_run`, `pull_request_target`, `merge_group` and every other
event before the checkout. `workflow_run` and `pull_request_target` run with the
base repository's privileges on a commit the pull request author controls, and
the App accepts none of these events.

## Modes

| Mode | Engine command | Payload | Sent to |
| --- | --- | --- | --- |
| `report` (default) | `check --json -c /bundle/.archfit.yaml --root /src` | state report | `<endpoint>/v1/reports` |
| `discovery` (`discover: true`) | `config init --root /src --output -` | draft policy | `<endpoint>/v1/discoveries` |
| `baseline` | `baseline -c /bundle/.archfit.yaml --root /src`, then `check` | `.archfit-baseline.json` | `<endpoint>/v1/baselines`; artifact only without `endpoint` |

Discovery and baseline run on the default branch only. Reports come from
`pull_request` and `push` runs; a `workflow_dispatch` run in `report` mode is
refused before any work, because the App accepts a dispatched run only as
discovery or baseline. Baseline mode fails unless the engine finds the captured
baseline comparable in the same image. A baseline captured on a laptop is not
comparable: the measurement profile records the platform and the tool versions.

With `endpoint`, baseline mode sends the captured file to the App, which opens
or updates a draft pull request from `archfit/baseline` that changes only
`.archfit-baseline.json`. The App never commits a baseline to the default
branch: it changes only when an architecture owner approves that pull request's
exact head commit and it is merged. Dispatch the capture on the current
default-branch head; the App refuses a capture of an older head. See
[Baseline answers](#baseline-answers). Without `endpoint`, commit the
`archfit-baseline` artifact as `.archfit-baseline.json` in a pull request that a
policy owner approves.

Each mode uploads its payload as a workflow artifact: `archfit-report` (the name
the App's graph view reads), `archfit-policy` or `archfit-baseline`.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `endpoint` | *(empty)* | App base URL (`https`, no trailing slash). The action appends `/v1/reports`, `/v1/discoveries` or `/v1/baselines`. Empty means analyze only. |
| `audience` | *(empty)* | OIDC audience. Empty means `endpoint`, verbatim. The App accepts exactly its base URL. |
| `engine-version` | *(required)* | Engine release of the image, for example `v2.3.1`. An image that reports another version is refused. |
| `image-digest` | *(required)* | Per-platform manifest digest of `ghcr.io/alexei-led/archfit` (`sha256:<64 hex>`). Tags are refused. |
| `mode` | *(empty)* | `report`, `discovery` or `baseline`. Empty means `report`, or `discovery` when `discover` is true. |
| `discover` | `false` | `true` selects discovery. The generated workflow passes its dispatch input here. |

## Outputs

| Output | Meaning |
| --- | --- |
| `verdict` | `healthy`, `needs_attention` or `blocked`; empty when nothing was measured. |
| `payload-file` | The report, draft policy or baseline the engine produced. |
| `envelope-file` | The envelope, exactly as sent in the `X-Archfit-Envelope` header. |
| `app-status` | HTTP status of the App's final answer; `000` when no answer arrived; empty when nothing was sent. |
| `app-answer` | The App's JSON answer on one line, for example `{"conclusion":"success","reason":"healthy"}`, `{"pull_request":12,"url":"…"}`, `{"unchanged":true}` or `{"error":"<code>"}`. |

The job status covers the run and the upload. On an accepted report the App's
checks carry the verdict. The step summary repeats the App's answer: the
conclusion and reason, the pull request number and URL, `unchanged`, or the
HTTP status and error code.

## Trusted inputs

The engine reads `.archfit.yaml`, `.archfit-baseline.json` and
`.archfit-labels.yaml` from `/bundle`. The action writes each file from its git
blob, never from the working tree, hashes it before the engine starts, and
mounts it read-only:

- On a pull request reported to the App, a file comes from the head commit when
  the pull request changes it (merge base to head, the diff behind GitHub's file
  list). Otherwise it comes from the tip of the base branch. The App trusts a
  head digest only when a policy owner approved that exact head commit.
- On a pull request without `endpoint`, every file comes from the tip of the
  base branch.
- On `push` and `workflow_dispatch`, the files come from the commit the run
  executed on.
- A missing file gives an empty digest. Without `.archfit.yaml` there is nothing
  to measure: the run says so, names the commit it read, and sends nothing.
- A pull request whose head and base have more than one merge base (criss-cross
  merges) is refused. Merge the base branch into it so that one merge base
  remains.

## The envelope

The envelope is owned by the archfit App: `archfit.report-envelope.v1`, 16 flat
typed keys. [`schema/`](schema/) holds the vendored copy, and
[`schema/SCHEMA_SOURCE`](schema/SCHEMA_SOURCE) names its App revision and
sha256. CI validates the envelopes the action builds for `pull_request` and
`push` reports, `workflow_dispatch` discovery, and `workflow_dispatch` and
`push` baselines against it. Checking that the vendored
bytes still equal the App's schema belongs in the App's CI.

The envelope states what was analysed: repository, event, pull request, head,
base and merge base, run, engine identity, and the digests of the payload and of
the baseline and labels files the engine read. Head, base and pull request come
from the event payload, never from the job context: a `pull_request` job's
`GITHUB_SHA` is a merge commit.

It is **not** a security claim. Every field is self-reported by a job that runs
pull-request code. The App binds the envelope to the OIDC token's claims and to
GitHub's own data and trusts no field alone. The measurement is
customer-attested.

## Upload

One `POST` per attempt: `Authorization: Bearer <OIDC token>`, the envelope in
`X-Archfit-Envelope`, the exact payload bytes as the body.

- Pre-checks: report at most 5 MiB, draft policy and baseline at most 1 MiB
  (1,048,576 bytes), envelope at most 8192 bytes on one line.
- Retries: on 429, 5xx and no answer, up to 5 attempts within 300 s. The wait
  is `Retry-After` in seconds (at most four digits, capped at 120 s). Any other
  value, an HTTP date included, falls back to 5 s doubling with ±20% jitter.
  Each attempt mints a fresh OIDC token.
- 409 on a report or a draft policy means a newer commit or run attempt
  supersedes the upload: a notice, not a failure. 409 on a baseline fails the
  job (see below). Every other answer is final; the error names the App's code
  and the fix.
- The App's answer reaches the log and the step summary only when each field has
  its documented shape: a lowercase code, a number, the JSON literal `true` or a
  GitHub URL. Anything else prints as `(unexpected value)`, so the answer cannot
  inject workflow commands or markdown.

### Baseline answers

The baseline upload is `POST <endpoint>/v1/baselines` with
`Content-Type: application/json` and the exact bytes of the captured
`.archfit-baseline.json` as the body. Its envelope has `kind: baseline`,
`pull_request: 0`, empty `base_sha` and `merge_base_sha`, the checked-out
default-branch commit as `head_sha`, an empty `baseline_digest` (the capture
reads no stored baseline), and the digest of the labels file the capture read
as `labels_digest` (empty without one). The captured file stays a workflow
artifact too.

| Answer | Job | Meaning |
| --- | --- | --- |
| 200 `{"pull_request": n, "url": "…"}` | passes | The App opened or updated the baseline pull request. An architecture owner approves its exact head commit and merges it. |
| 200 `{"unchanged": true}` | passes | The capture equals the baseline on the default branch. Nothing was written. |
| 409 `stale_head`, `stale_attempt` | fails | The default branch moved on, or a newer run attempt exists. No pull request was opened: dispatch the capture again. |
| 400, 401, 403, 413 | fails | Final. The error names the code and the fix, for example `policy_mismatch` or `labels_mismatch` (dispatch again on the current head), `unknown_engine_identity` (pin the manifest's image) or `baseline_too_large`. |
| 429, 5xx, no answer | retried | As for every upload. |

## Edge cases

- **Fork pull requests** get no OIDC token from GitHub. The action analyzes and
  keeps the report as an artifact, sends nothing, and exits 0. The App marks the
  pull request `fork_unsupported`.
- **No policy** on the protected ref: nothing is measured or sent. Dispatch the
  workflow with `discover: true` on the default branch.
- **Engine exit 3** (no report): the job fails with the engine's last lines and
  sends nothing.

## The container

The engine runs as `docker run ghcr.io/alexei-led/archfit@<digest>` with:

- the workspace owner's uid and gid, `HOME=/tmp`, all capabilities dropped, and
  no other environment: no token, no OIDC variable, no credential;
- the checkout at `/src`, with its `.git` read-only;
- each trusted input mounted read-only at `/bundle/<name>`, over an empty
  writable `/bundle` directory. The engine keeps its fact cache
  (`.archfit-cache/`) there, next to the config, and baseline mode writes
  `.archfit-baseline.json` there.

The action refuses a checkout that keeps credentials anywhere the container
could read them: auth headers, credential helpers, `url.*.insteadOf` rewrites,
`includeIf` entries, or remote URLs with a user name or token, in `.git/config`
or in a submodule's `.git/modules/*/config`.

The working tree stays writable because analyzers write there: `uv run` creates
`.venv` and `uv.lock` in a Python project. Treat the checkout as scratch after
the action ran. The engine's repair commands name the container layout
(`archfit check -c /bundle/.archfit.yaml --root /src`); run
`archfit check -c .archfit.yaml` locally.

When the pull request does not carry a baseline, nothing is mounted at
`/bundle/.archfit-baseline.json`, and that path is writable. The engine loads
the baseline before any analyzer runs, so analysis cannot plant one there.

The action does not pass `--base`: the engine would create a git worktree, which
the read-only `.git` forbids. The report therefore has no merge-base
comparison, and agent-task origins against the merge base are not computed.

Dependencies the analyzers fetch (Go modules, grimp) come from public
registries. The container gets no credentials for private ones.

## Requirements

A Linux runner with `docker`, `git`, `jq` and `curl`; `ubuntu-latest` has all of
them. The job needs `id-token: write` once `endpoint` is set. The image
platform must equal the runner's (`X64` → `linux/amd64`, `ARM64` →
`linux/arm64`): pin the digest the App's manifest lists for that platform.

## Development

```sh
curl -fsSLo /tmp/state.json https://raw.githubusercontent.com/alexei-led/archfit/f8877d25ba36d84d3780071580d23486e3d794d0/internal/extract/golang/testdata/single-module/baseline.json
ARCHFIT_TEST_STATE=/tmp/state.json bash tests/run.sh   # needs git, jq, curl, python3, go
bash tests/engine-smoke.sh                             # needs docker and network
shellcheck -x scripts/*.sh tests/*.sh tests/fakes/docker
```

`tests/run.sh` runs the shipped scripts against scratch repositories, with a
docker shim, a local App and token server, and a no-op `sleep`.
`tests/engine-smoke.sh` runs the real pinned image.

## License

Apache-2.0. See [LICENSE](LICENSE).
