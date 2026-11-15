# archfit-action

Composite GitHub Action that runs the pinned archfit engine image in the caller's
runner and sends the result to the archfit App. It checks out the change, reads the
policy from the target branch's tip, runs the image once, writes the envelope and uploads.

Three repositories, one product. The boundary is deliberate: a **tenant-bearing
service** versus an **analyzer the customer executes**, with a narrow protocol
between them.

| Repo                                               | Owns                                                                                             |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| [`archfit`](https://github.com/alexei-led/archfit) | engine, CLI, images, the result contract (Apache-2.0)                                            |
| `archfit-action` (this one)                        | the execution and upload adapter (Apache-2.0)                                                    |
| `archfit-app`                                      | tenancy, approved policy, requests and answers, PR feedback, **the envelope contract** (private) |

Start here: new work follows the [Archfit 4 design](https://github.com/alexei-led/archfit/blob/main/docs/plans/20261110-archfit-4-architecture-change-control.md)
in `archfit`, the current design for the engine, this Action and the App.

## Layout

- `action.yml` — composite action: prepare → `actions/checkout` → run → `actions/upload-artifact` → report
- `scripts/prepare.sh` — validate inputs, refuse events, name the commit to check out
- `scripts/run.sh` — target tip, merge base, the policy the engine judges with, image identity, one engine run
- `scripts/report.sh` — envelope 2, OIDC token, upload with retries, the App's answer
- `scripts/lib.sh` — shared helpers and the engine pin (sourced)
- `schema/` — vendored App envelope schema + `SCHEMA_SOURCE` (App repository, revision, path, sha256)
- `tests/run.sh` — conformance and behaviour tests: the shipped scripts on scratch repos,
  with `tests/fakes/docker` (engine shim), `tests/fakes/app.py` (App + OIDC token server),
  `tests/events/` (event payloads), `tests/validate/` (Go envelope validator, pinned by go.sum)
- `tests/engine-smoke.sh` — the real pinned image (CI only; needs docker)
- `tests/fixtures/result/` — results the pinned engine emitted (the docker shim replays them),
  hash-pinned in `tests/fixtures/SOURCE.md`

## Invariants

- **The App owns the envelope** (`archfit-app` `internal/wire/envelope`,
  `archfit.upload-envelope.v2`). This repo vendors `schema/envelope.v2.schema.json` byte
  for byte and conforms. Change it only by re-vendoring a new App revision: update
  `SCHEMA_SOURCE` and its sha256 in the same commit. No compatibility is kept with older
  App schemas or engine versions: the Action runs the engine `lib.sh` pins only.
- **The envelope states what was checked; it proves nothing.** Every field is
  self-reported. The identity fields (`engine_version`, `image_digest`, `platform`),
  `target_sha` and `policy_digest` are claims the App compares with its manifest and with
  the default branch on GitHub. Never word one as an attestation.
- **The checked commit is tied to the event payload; the job context only locates it.**
  A pull request is checked at its head, `pull_request.head.sha`: the commit the App binds
  the result to (the workflow run's `head_sha`), never the test merge commit. A push is
  checked at `GITHUB_SHA` of a branch ref; a tag push is refused. A merge group is
  checked at the event's `merge_group.head_sha` (= `GITHUB_SHA`, and `GITHUB_REF` =
  `head_ref`, else refused before checkout); the event's `base_sha` must be an ancestor
  of it and of the fetched default branch. The queue branch name is never parsed.
- **The policy comes only from the target tip** (design 9.1). The target tip is
  `refs/remotes/origin/<branch>` as `actions/checkout` (fetch-depth 0) fetched it in this
  run: the pull request's `base.ref`, the pushed branch, or the default branch for a merge
  group. A re-run fetches again, so it reads the tip as it is then (design 10.5). The
  engine gets the full ref: a tag named `origin/<branch>` would win the short name.
  - When the change (merge base..head) leaves `.archfit.yaml` alone, the tip's blob is
    written from git objects into `RUNNER_TEMP`, mounted read-only outside `/src` and
    passed with `--policy`. Never read it from the working tree (eol rules change the bytes).
  - When the change edits the policy, or the head is the tip (a push at the tip), there is
    no `--policy`: the engine compares the checkout's file with the tip's, and a difference
    is `unknown`. So a push at the tip of a repository whose `.gitattributes` converts
    `.archfit.yaml` is `unknown`: the engine compares working-tree bytes with the blob.
  - When the analysed commit deletes the root policy, the Action emits an `unknown`
    result naming the missing policy, with the target blob's digest, without running the
    engine. The CLI treats a missing policy as a usage error, not a change verdict.
  - `merge_base_sha` is the single `git merge-base --all` of head and the tip; several
    (criss-cross) are refused.
- **One engine pass.** `check --format json --base refs/remotes/origin/<branch>
[--policy …]`, nothing else: no `config compare`, no self-check, no second run. The exit
  code and the result's `status` must agree (0 pass, 1 fail, 2 unknown); exit 2 with no
  result is a tool error, and `waiting` is the App's status, never the engine's. The
  result bytes are the upload body and the `archfit-result` artifact, unchanged (the
  `repository` block of a push at the tip included). Only the missing-policy result
  above is generated by the Action rather than the engine.
- **No credentials are forwarded.** Only fixed HOME and checkout-scoped Git settings
  enter the container. `safe.directory=/src` is command-environment config, never
  host/global config or wildcard trust. No `--env-file`, no bare `-e NAME` (it copies
  the host value), no `ACTIONS_*`, no token. `.git` is mounted read-only, and nothing in
  it is writable. Refuse a checkout with credential keys (`extraheader`, `credential.*`,
  `url.*.insteadOf`, `includeIf.*`) or a userinfo remote URL in `.git/config` or
  `.git/modules/*/config`. The OIDC token is minted after the container exits. Run no
  git on the runner after the container has run.
- **The working tree is writable on purpose** for target build tools and indexers.
  A fresh, empty `RUNNER_TEMP` directory is mounted over `/src/.archfit-cache`, writable:
  checkout-supplied cached facts are never read, and engine cache writes stay outside the
  checkout. The result is read from stdout into `RUNNER_TEMP`, outside every mount.
- **Only the events the App accepts.** `pull_request`, `push` to a branch and
  `merge_group`; every other event (`workflow_run`, `pull_request_target`,
  `workflow_dispatch`) is refused in `prepare.sh` before the checkout. `merge_group` only
  with action `checks_requested` and `base_ref` = the default branch.
- **Without an endpoint the job is the gate.** Nothing is sent; only `pass` passes, and
  `fail` or `unknown` fails the job.
- **The endpoint is https and exact.** No trailing slash (it is also the OIDC audience);
  plain http only for 127.0.0.1/localhost. App answer fields are printed only when they
  match their documented shape.
- **Stay a composite action.** The App accepts envelope 2 only from
  `.github/workflows/archfit.yaml` as the run's own top-level workflow (`job_workflow_ref`);
  a reusable workflow would change that binding.
- **Nested actions are pinned by full commit SHA**, with the tag in a comment. The App
  pins this action by commit; a tag inside it would make that commit's behaviour mutable.
- **Retries only on 429, 5xx and no answer.** 409 (`stale_run`, `stale_head`,
  `stale_group`) means superseded (exit 0): a newer run uploads its own, and the App
  writes nothing for this one. Every other answer is final. `Retry-After` counts only as
  1-4 decimal digits; else backoff.
- **Fork pull requests cannot hold `id-token: write`.** They are checked and kept as
  an artifact, never uploaded. Do not add a fallback that makes them look enforceable.
- **The release pins the engine.** `engine-version` and `image-digest` are optional:
  omitted, they are `SUPPORTED_ENGINE_VERSION` and the per-platform digest in `lib.sh`
  for `RUNNER_ARCH`, so a consumer upgrades with one action-commit bump. Given, they
  are checked exactly as before. A pin PR moves the version and both digests together.
- **Analyzer identity is part of the result.** Pin the image by its per-platform digest.
  Never suggest `:latest` or a tag. The image platform must equal the runner's
  (`RUNNER_ARCH`); `engine_version` must equal the input. Both are checked before analysis.

## Conventions

- Bash, `set -euo pipefail`, shellcheck-clean (`shellcheck -x`), shfmt-formatted.
  `jq`, `curl`, `git` and `docker` may be assumed on the runner; nothing else.
- Invoke scripts as `bash path/to/script.sh`, in `action.yml` and in tests; do not rely
  on file modes.
- Tests fake only process and network boundaries (docker, the App, `sleep`). The results
  they replay are ones the engine emitted, hash-pinned in `tests/fixtures/SOURCE.md`
  with the engine commit, never a stub written to match this action.
- A new check proves it can fail: the validator has known-bad envelopes it must reject.
- Releases are tagged `vN`; the App pins a commit SHA.
