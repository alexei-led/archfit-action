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
  `pull_request` job's `GITHUB_SHA` is a merge commit. `base_sha` is the event's
  `pull_request.base.sha` (the App compares it with the API's `base.sha`);
  `merge_base_sha` is the single `git merge-base --all` of that and head (several =
  criss-cross, refused).
- **Trusted inputs come from git blobs, per file.** On a pull request reported to the
  App a file comes from head when merge-base..head changes it, else from the base tip.
  Without an endpoint nobody checks owner approval, so every file comes from the base
  tip, and a head that deletes the policy fails. Push and dispatch read the run's
  commit. Digests are taken before the container starts. Never read them from the
  working tree (eol rules change the bytes).
- **The container gets nothing secret.** No `--env-file`, no bare `-e NAME` (it copies
  the host value), no `ACTIONS_*`, no token. `.git` is mounted read-only; refuse a
  checkout with credential keys (`extraheader`, `credential.*`, `url.*.insteadOf`,
  `includeIf.*`) or a userinfo remote URL in `.git/config` or `.git/modules/*/config`.
  The OIDC token is minted after the container exits. Run no git on the runner after
  the container has run.
- **Inputs are read-only, the rest is writable on purpose.** Each trusted input is
  mounted `:ro` over `/bundle/<name>`; `/bundle` itself is an empty writable directory
  for the fact cache and a captured baseline. The working tree is writable: `uv run`
  writes `.venv` and `uv.lock`. Payloads are read from stdout into `RUNNER_TEMP`,
  outside every mount. No `--base`: it needs a writable `.git`.
- **Only the events the App accepts.** `pull_request`, `push` and `workflow_dispatch`;
  every other event (`workflow_run`, `pull_request_target`, `merge_group`) is refused
  in `prepare.sh` before the checkout. A `workflow_dispatch` report is refused too (the
  App's `eligible()` table); dispatch runs discovery or baseline.
- **The endpoint is https and exact.** No trailing slash (it is also the OIDC audience);
  plain http only for 127.0.0.1/localhost. App answer fields are printed only when they
  match their documented shape.
- **Stay a composite action.** The App binds `job_workflow_ref` to the caller's workflow
  file; a reusable workflow would change that binding.
- **Nested actions are pinned by full commit SHA**, with the tag in a comment. The App
  pins this action by commit; a tag inside it would make that commit's behaviour mutable.
- **Retries only on 429, 5xx and no answer.** 409 on a report or draft is superseded
  (exit 0): the newer run uploads its own. 409 on a baseline (`stale_head`,
  `stale_attempt`) fails the job with "dispatch the capture again": nothing re-proposes
  it. Every other answer is final. `Retry-After` counts only as 1-4 decimal digits;
  else backoff.
- **A baseline is proposed, never committed.** With an endpoint, baseline mode posts the
  captured `.archfit-baseline.json` bytes (at most 1 MiB, `application/json`) to
  `/v1/baselines`, and the App opens or updates an owner-reviewed pull request; it
  answers `{pull_request,url}` or `{unchanged:true}`. Envelope: `kind: baseline`,
  `pull_request` 0, empty `base_sha`/`merge_base_sha`, `head_sha` = the checked-out
  default-branch commit, `baseline_digest` "" (the capture reads no stored baseline, so
  the self-check copy is never materialized into `inputs.tsv`), `labels_digest` = the
  labels blob the capture read, or "". Without an endpoint the capture is an artifact
  only and no envelope is written. `unchanged` counts only as the JSON literal `true`.
- **Fork pull requests cannot hold `id-token: write`.** They are analysed and kept as
  an artifact, never uploaded. Do not add a fallback that makes them look enforceable.
- **Analyzer identity is part of the result.** Pin the image by its per-platform digest.
  Never suggest `:latest` or a tag. The image platform must equal the runner's
  (`RUNNER_ARCH`); `engine_version` must equal the input. Both are checked before analysis.

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
