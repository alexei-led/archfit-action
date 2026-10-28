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
      mode:
        description: discovery (propose a policy), baseline (capture accepted debt) or reanchor (carry the baseline to this engine)
        type: choice
        options: [discovery, baseline, reanchor]
        default: discovery

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
          engine-version: "v3.2.3"
          image-digest: "sha256:87323e8d80d519531338ff7a36ce750d337ecf6560e48493bdeb10b864e7b772"
          mode: ${{ github.event_name == 'workflow_dispatch' && inputs.mode || '' }}
```

Do not add a checkout step: the action does its own, without persisted
credentials.

Without `endpoint` the action analyzes only: nothing is sent, the report or the
captured baseline is a workflow artifact. For reports, this job is the local gate:
`blocked`, unavailable required evidence (`decision.hard_gates` not `pass` or
nonempty `decision.unevaluated_required_rules`), active blockers, or missing/invalid
decision evidence fail the job. Optional `needs_attention` still succeeds when the
hard gates pass and no required rules are unevaluated. An omitted empty required-rule
list is valid; an explicit `null` or a non-array is not. This local gate is not App
approval. No App checks that a policy owner approved a pull request's change to
the policy, baseline or labels, so a pull request is measured against the base
branch's files only. Its own edits to them have no effect, and a pull request that
deletes `.archfit.yaml` fails.

`endpoint` is the App base URL over `https`, without a trailing slash. Plain
`http` is accepted only for `127.0.0.1` and `localhost`.

The action runs on `pull_request`, `push` and `workflow_dispatch` only. It
refuses `workflow_run`, `pull_request_target`, `merge_group` and every other
event before the checkout. `workflow_run` and `pull_request_target` run with the
base repository's privileges on a commit the pull request author controls, and
the App accepts none of these events.

### Concurrency

Pushes in quick succession would otherwise queue a stale run for each commit. A
hand-written workflow can cancel the older pull request run when a new commit
arrives:

```yaml
concurrency:
  group: archfit-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

The group is the pull request number, so runs of two pull requests never
cancel each other, even when their branches share a name. Only pull request runs
are cancelled. A cancelled run uploads nothing, and the App answers the newer
head. A `push` to a branch and a dispatched baseline or reanchor on that branch
share a group, and cancelling one of them would drop its upload, so they are
never cancelled. A run waiting in the queue can still be replaced by a newer run
in the same group. Dispatch a baseline or reanchor again when its run is
replaced.

## Modes

| Mode | Engine command | Payload | Sent to |
| --- | --- | --- | --- |
| `report` (default) | `check --json -c /bundle/.archfit.yaml --root /src`, plus `--base <base>` on a pull request | state report | `<endpoint>/v1/reports` |
| `discovery` | `config init --root /src --output -` | draft policy | `<endpoint>/v1/discoveries` |
| `baseline` | `baseline -c /bundle/.archfit.yaml --root /src`, then `check` | `.archfit-baseline.json` | `<endpoint>/v1/baselines`; artifact only without `endpoint` |
| `reanchor` | `baseline --reanchor --from /reference/.archfit-baseline.json -c /bundle/.archfit.yaml --root /src`, then `check` | the new `.archfit-baseline.json` | `<endpoint>/v1/reanchors`; artifact only without `endpoint` |

Discovery, baseline and reanchor run on the default branch only. Reports come
from `pull_request` and `push` runs; a `workflow_dispatch` run in `report` mode
is refused before any work, because the App accepts a dispatched run only as
discovery, baseline or reanchor. Baseline and reanchor mode fail unless the
engine finds the captured baseline comparable in the same image. A baseline
captured on a laptop is not comparable: the measurement profile records the
platform and the tool versions.

`reanchor` carries the accepted debt of the protected baseline to this engine.
It needs a `.archfit-baseline.json` on the default branch; without one the job
fails before the engine runs, and the first baseline is a `baseline` capture.
The engine keeps a finding only when the stored file accepted it, so the new
file accepts no new debt. The engine's report is printed in the log, written to
the step summary and kept in the `archfit-baseline` artifact next to the file. It
lists each kept, dropped and unaccepted finding, each seam that changed, and each
metric that got worse. Review it before you merge the baseline pull request. The
App gets only the file: it computes the same differences from the two files
itself.

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
the App's graph view reads), `archfit-policy`, or `archfit-baseline` for both
baseline and reanchor (a reanchor also keeps the engine's report there).

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `endpoint` | *(empty)* | App base URL (`https`, no trailing slash). The action appends `/v1/reports`, `/v1/discoveries`, `/v1/baselines` or `/v1/reanchors`. Empty means analyze only. |
| `audience` | *(empty)* | OIDC audience. Empty means `endpoint`, verbatim. The App accepts exactly its base URL. |
| `engine-version` | *(required)* | Engine release of the image, for example `v3.2.3`. An image that reports another version is refused. |
| `image-digest` | *(required)* | Per-platform manifest digest of `ghcr.io/alexei-led/archfit` (`sha256:<64 hex>`). Tags are refused. |
| `mode` | *(empty)* | `report`, `discovery`, `baseline` or `reanchor`. Empty means `report`. |

## Outputs

| Output | Meaning |
| --- | --- |
| `verdict` | `healthy`, `needs_attention` or `blocked`; empty when nothing was measured. |
| `payload-file` | The report, draft policy or baseline the engine produced. |
| `report-file` | The engine's re-anchor report; empty unless `mode` is `reanchor`. |
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

## Origin on pull requests

On a `pull_request` run, the report check runs with `--base <base>`. The engine
checks that commit out in a temporary worktree and scores it with the same
trusted inputs. Then it marks each finding of the analysed commit. The base is the
event's base commit when the merge commit is analysed (it already holds the
target's own changes, so only the pull request's findings count as introduced),
and the merge base when the head is analysed alone:

- `findings[].origin` and `agent_tasks[].origin`: `introduced` (the pull request
  added it), `pre_existing` (the base has it too), or `unknown` (the
  analyzer evidence of the two sides did not pair);
- `comparison.origin_status` (`comparable` or `unknown`) and
  `comparison.origin_reasons`;
- `comparison.introduced_finding_ids` and `comparison.resolved_finding_ids`.

The step summary gives the origin status and the two counts. Origin is
report-only: the verdict and the exit code are those of the analysed commit
alone. `push` runs have no base and no origin fields.

Cost: one `--base` run analyses both trees, so a pull request run takes about
two engine passes of time.

When the `--base` run ends without a report (exit 3 for a git or worktree
error, or a crash), the job does not fail for that. The log shows the engine's
reason and a warning that origin is missing for this run. The check then runs
again without `--base`, and that run's report is the one kept and sent. If that
run fails too, the job fails as before. The rerun starts from an empty `/bundle`,
so a file the first run wrote there (a baseline where none is mounted, the fact
cache) cannot reach it. The working tree is not reset: the rerun analyses the
checkout as the first run left it. Analysed code can already change files during
one run; the rerun gives it a whole run to do so. A `--base` run that hangs is
bounded by the job's `timeout-minutes`, like any engine run.

## Policy change

When a pull request changes `.archfit.yaml`, the action asks the engine what the
change does to what blocks: `archfit config compare <head policy> -c <base policy>
--json` (`archfit.config-compare.v1`). The head's file is the candidate, because it
is what an owner would approve; the base tip's file is the current policy. The
classification reads the two files' declarations. The comparison around it still
measures the tree under both policies, so it takes as long as two analyses.

The document is kept as the `archfit-policy-change` artifact, byte for byte as the
engine printed it, and the step summary gives its direction and counts:

- `loosens`: rules removed or loosened, waivers added, allowlists widened;
- `tightens`: the mirror of those lists;
- `coverage lost`: source that is no longer measured (an exclude added, a language
  or analyzer turned off, a module or its paths removed).

The action runs the comparison only with an engine that prints the classification:
v3.4.0 and later. With the pinned v3.2.3 it does not run, and the summary says so.
The release that moves the pin to v3.4.0 turns it on.

The engine's `policy_change` object also goes to the App, verbatim, as the
envelope's optional `policy_change` field; the report payload is unchanged. It is
left out when the change orders nothing (`direction: none`), when nothing was
classified, and when it would make the envelope larger than the App's 8192-byte
cap (the log warns; the artifact still holds it). An envelope without it says
nothing about whether the policy changed.

This section is report-only. A failed classification is a warning and the verdict
and the exit code are unchanged. A pull request that does not change
`.archfit.yaml`, every `push` and every `workflow_dispatch` run skip it.

## The envelope

The envelope is owned by the archfit App: `archfit.report-envelope.v1`, 18 flat
typed keys, plus the optional `policy_change` object on a pull request report (see
[Policy change](#policy-change)). [`schema/`](schema/) holds the vendored copy, and
[`schema/SCHEMA_SOURCE`](schema/SCHEMA_SOURCE) names its App revision and
sha256. CI validates the envelopes the action builds for `pull_request` and
`push` reports and for the discovery, baseline and reanchor envelopes against it.
Checking that the vendored bytes still equal the App's schema belongs in the App's
CI.

The envelope states what was analysed: repository, event, pull request, head,
base and merge base, the commit analysed and how the pull request integrates,
run, engine identity, and the digests of the payload and of the baseline and
labels files the engine read. Head, base and pull request come from the event
payload, never from the job context. The merge commit is located by the job
(see below) and accepted only when the event confirms it.

`head_sha` is the pull request head, the commit an owner approves.
`analyzed_sha` is the commit the engine measured: the run's test merge commit of
the head into the base (`integration: merged`), or the head itself when the event
reports the pull request as conflicting (`integration: conflicts`). The merge
commit is the run's `GITHUB_SHA` on `refs/pull/<number>/merge`, and the action
accepts it only when its parents are exactly the event's base and head: the
event's own `merge_commit_sha` is filled in by GitHub after the event is sent
and is often null. Off pull requests `analyzed_sha` equals `head_sha` and
`integration` is empty.

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
  supersedes the upload: a notice, not a failure. 409 on a baseline or a
  re-anchor fails the job (see below). Every other answer is final; the error names the App's code
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

A re-anchor upload is `POST <endpoint>/v1/reanchors`, with the same body rules
and `kind: reanchor`. Its `baseline_digest` is required: the SHA-256 of the
protected `.archfit-baseline.json` the engine read, the blob at `head_sha`.
The App reads that blob itself and requires equality.

| Answer | Job | Meaning |
| --- | --- | --- |
| 200 `{"pull_request": n, "url": "…"}` | passes | The App opened or updated the baseline pull request. An architecture owner approves its exact head commit and merges it. |
| 200 `{"unchanged": true}` | passes | The capture equals the baseline on the default branch. Nothing was written. |
| 409 `stale_head`, `stale_attempt` | fails | The default branch moved on, or a newer run attempt exists. No pull request was opened: dispatch the capture or the re-anchor again. |
| 400, 401, 403, 413 | fails | Final. The error names the code and the fix, for example `policy_mismatch` or `labels_mismatch` (dispatch again on the current head), `unknown_engine_identity` (pin the manifest's image), `baseline_too_large`, or `reanchor_digest_mismatch`, `reanchor_baseline_missing` and `reanchor_not_subset` for a re-anchor. |
| 429, 5xx, no answer | retried | As for every upload. |

## Edge cases

- **Fork pull requests** get no OIDC token from GitHub. With `endpoint`, the action
  analyzes and keeps the report as an artifact, sends nothing, and exits 0. The
  App marks the pull request `fork_unsupported`. Without `endpoint`, the local
  report gate described above applies.
- **No policy** on the protected ref: nothing is measured or sent. Dispatch the
  workflow with `mode: discovery` on the default branch.
- **Engine exit 3** (no report, or a stored baseline the engine cannot
  re-anchor): the job fails with the engine's last lines and sends nothing. A
  re-anchor exits 3 when the stored file is missing or older than schema v2, or
  when the flags conflict.
- **Base comparison fails** on a pull request: the check runs again without
  `--base`, and the report has no origin. See
  [Origin on pull requests](#origin-on-pull-requests).

## The container

The engine runs as `docker run ghcr.io/alexei-led/archfit@<digest>` with:

- the workspace owner's uid and gid, all capabilities dropped, and fixed
  `HOME=/tmp` plus container-only Git trust for `/src`. No token, OIDC variable,
  credential, or copied host environment. No host/global Git config changes;
- the checkout at `/src`, with its `.git` read-only. On a pull request only, an
  empty directory from `RUNNER_TEMP` is mounted writable over
  `/src/.git/worktrees` (see below);
- each trusted input mounted read-only at `/bundle/<name>`, over an empty
  writable `/bundle` directory. The engine keeps its fact cache
  (`.archfit-cache/`) there, next to the config, and baseline and reanchor mode
  write `.archfit-baseline.json` there;
- in reanchor mode only, the protected baseline mounted read-only at
  `/reference/.archfit-baseline.json`. It is outside `/bundle`, so the engine
  cannot read its output as its input.

The action refuses a checkout that keeps credentials anywhere the container
could read them: auth headers, credential helpers, `url.*.insteadOf` rewrites,
`includeIf` entries, or remote URLs with a user name or token, in `.git/config`
or in a submodule's `.git/modules/*/config`.

The working tree stays writable because target build tools and indexers can write
there. Treat the checkout as scratch after
the action ran. The engine's repair commands name the container layout
(`archfit check -c /bundle/.archfit.yaml --root /src`); run
`archfit check -c .archfit.yaml` locally.

When the pull request does not carry a baseline, nothing is mounted at
`/bundle/.archfit-baseline.json`, and that path is writable. The engine loads
the baseline before any analyzer runs, so analysis cannot plant one there.

`--base` checks the base commit out with `git worktree add --detach`. That
command writes only `.git/worktrees/<name>` (`HEAD`, `index`, `gitdir`). So for
that run an empty `RUNNER_TEMP` directory is mounted writable over
`/src/.git/worktrees`, and the rest of `.git` stays read-only. Git on the
runner never reads that directory. The host `.git/worktrees` is an empty
mountpoint, created before the container starts. The worktree files go under
`/src/.archfit-cache/worktrees/`, in the writable working tree. The engine
removes its worktree when it finishes, but leaves a lock file, and a killed run
leaves the whole tree. So after the container exits the action deletes
`.archfit-cache/worktrees`. If the container made that path a symlink, the
action leaves it in place and warns, so it never deletes outside the checkout.

The image preinstalls its analyzers. Target build tools and indexers can execute
code and fetch project dependencies. The container receives no registry credentials.
It is not network-isolated: target code can exfiltrate mounted source.
Reports remain customer-attested, not independent proof of execution.

Report, baseline capture, reanchor, and their self-checks use `--refresh`. This avoids
reusing local analyzer caches for a published run. It does not make untrusted code safe.

## Requirements

A Linux runner with `docker`, `git`, `jq` and `curl`; `ubuntu-latest` has all of
them. The job needs `id-token: write` once `endpoint` is set. The image
platform must equal the runner's (`X64` → `linux/amd64`, `ARM64` →
`linux/arm64`): pin the digest the App's manifest lists for that platform.

## Development

```sh
ARCHFIT_TEST_STATE=tests/fixtures/state.json bash tests/run.sh # git, jq, curl, python3, go
bash tests/report-evidence.sh                              # report-stage guard only
bash tests/engine-smoke.sh                                 # native docker and network
shellcheck -x scripts/*.sh tests/*.sh tests/fakes/docker
```

`tests/run.sh` drives the shipped scripts on scratch repositories. Only process and
network boundaries are faked. Its state and reanchor fixtures are unmodified outputs
from the released v3.2.3 image. [Fixture provenance](tests/fixtures/SOURCE.md) records
producer identity and byte hashes. The stored v3.0.0 baseline remains historical.

`tests/report-evidence.sh` replays genuine release captures through the report stage,
plus deliberate malformed/contradictory negative inputs. Its transport wrappers are
synthetic, not execution proof. [Guard fixture provenance](tests/fixtures/required-evidence/SOURCE.md)
records the actual release workflow, platform digest, and hashes.

`tests/engine-smoke.sh` runs the real published platform image. CI tests both native
Linux platforms and uploads `engine-fixtures-amd64` / `engine-fixtures-arm64` artifacts
when `ARCHFIT_FIXTURES_OUT` is set. App approval and connected runs remain separate gates.

## License

Apache-2.0. See [LICENSE](LICENSE).
