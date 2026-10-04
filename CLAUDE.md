# archfit-action

Composite GitHub Action that runs the pinned archfit engine image in the caller's
runner and reports the result to the archfit App. It checks out the commit,
materializes the trusted inputs, runs the image, writes the envelope and uploads.

Three repositories, one product. The boundary is deliberate: a **tenant-bearing
service** versus an **analyzer the customer executes**, with a narrow protocol
between them.

| Repo | Owns |
| --- | --- |
| [`archfit`](https://github.com/alexei-led/archfit) | engine, CLI, images, the state report contract (Apache-2.0) |
| `archfit-action` (this one) | the execution and upload adapter (Apache-2.0) |
| `archfit-app` | tenancy, approved policy, baselines, PR feedback, **the envelope contract** (private) |

The design plan lives in `archfit-app` under `docs/plans/`.

## Layout

- `action.yml` — composite action: prepare → `actions/checkout` → run → `actions/upload-artifact` → report
- `scripts/prepare.sh` — validate inputs, pick the mode, name the commit to check out
- `scripts/run.sh` — revisions, trusted inputs from git blobs, image identity, engine run
- `scripts/report.sh` — envelope, OIDC token, upload with retries, the App's answer
- `scripts/lib.sh` — shared helpers (sourced)
- `schema/` — vendored App envelope schema + `SCHEMA_SOURCE` (App path, revision, sha256)
- `tests/run.sh` — conformance and behaviour tests: the shipped scripts on scratch repos,
  with `tests/fakes/docker` (engine shim), `tests/fakes/app.py` (App + OIDC token server),
  `tests/events/` (event payloads), `tests/validate/` (Go envelope validator, pinned by go.sum)
- `tests/engine-smoke.sh` — the real pinned image (CI only; needs docker)

## Invariants

- **The App owns the envelope** (`archfit-app` decisions.md §3; `internal/wire/envelope`).
  This repo vendors `schema/envelope.v1.schema.json` byte for byte and conforms. Change
  it only by re-vendoring a new App revision: update `SCHEMA_SOURCE` and its sha256 in
  the same commit. An additive App change ships in the App first.
- **The envelope states what was analysed; it proves nothing.** Every field is
  self-reported. The identity fields (`engine_version`, `image_digest`, `platform`) and
  the input digests are claims the App compares with its manifest and the protected
  ref. Never word one as an attestation.
- **The analysed commit comes from the event payload, never from the job context.** A
  `pull_request` job's `GITHUB_SHA` is a merge commit; a `workflow_run` job runs the
  default branch. `base_sha` is the event's `pull_request.base.sha` (the App compares
  it with the API's `base.sha`); `merge_base_sha` is `git merge-base` of that and head.
- **Trusted inputs come from git blobs, per file.** On a pull request a file comes from
  head when merge-base..head changes it, else from the base tip; on other events from
  the run's commit. Digests are taken before the container starts. Never read them
  from the working tree (eol rules change the bytes).
- **The container gets nothing secret.** No `--env-file`, no bare `-e NAME` (it copies
  the host value), no `ACTIONS_*`, no token. `.git` is mounted read-only; refuse a
  checkout with credentials in `.git/config`. The OIDC token is minted after the
  container exits. Run no git on the runner after the container has run.
- **The working tree is writable on purpose**: `uv run` writes `.venv` and `uv.lock`.
  So is `/bundle`: the engine's fact cache lives next to the config and baseline mode
  writes there; digests are taken before the container starts. Payloads are read from
  stdout into `RUNNER_TEMP`, outside every mount. No `--base`: it needs a writable `.git`.
- **Stay a composite action.** The App binds `job_workflow_ref` to the caller's workflow
  file; a reusable workflow would change that binding.
- **Nested actions are pinned by full commit SHA**, with the tag in a comment. The App
  pins this action by commit; a tag inside it would make that commit's behaviour mutable.
- **Retries only on 429, 5xx and no answer.** 409 is superseded (exit 0); every other
  answer is final.
- **Fork pull requests cannot hold `id-token: write`.** They are analysed and kept as
  an artifact, never uploaded. Do not add a fallback that makes them look enforceable.
- **Analyzer identity is part of the result.** Pin the image by its per-platform digest.
  Never suggest `:latest` or a tag. The image platform must equal the runner's
  (`RUNNER_ARCH`); `engine_version` must equal the input. Both are checked before analysis.
- **Only the events the App accepts.** Reports from `pull_request` and `push`; a
  `workflow_dispatch` report is refused in `prepare.sh` (the App's `eligible()` table).

## Conventions

- Bash, `set -euo pipefail`, shellcheck-clean (`shellcheck -x`), shfmt-formatted.
  `jq`, `curl`, `git` and `docker` may be assumed on the runner; nothing else.
- Invoke scripts as `bash path/to/script.sh`, in `action.yml` and in tests; do not rely
  on file modes.
- Tests fake only process and network boundaries (docker, the App, `sleep`). The state
  document they replay is one the engine emitted, fetched at a pinned commit with its
  sha256, never a stub written to match this action.
- A new check proves it can fail: the validator has known-bad envelopes it must reject.
- Releases are tagged `vN`; the App pins a commit SHA.
