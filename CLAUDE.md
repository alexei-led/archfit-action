# archfit-action

Composite GitHub Action that carries an archfit report out of a CI run. It does
not analyze anything — the analysis runs in the caller's runner, inside the
`ghcr.io/alexei-led/archfit` image.

Three repositories, one product. The boundary is deliberate: a **tenant-bearing
service** versus an **analyzer the customer executes**, with a narrow protocol
between them.

| Repo | Owns |
| --- | --- |
| [`archfit`](https://github.com/alexei-led/archfit) | engine, CLI, images, wire contracts (Apache-2.0) |
| `archfit-action` (this one) | the execution/upload adapter (Apache-2.0) |
| `archfit-app` | tenancy, approved policy, baselines, PR feedback (private) |

The design plan lives in `archfit-app` under `docs/plans/`.

## Layout

- `action.yml` — composite action, inputs/outputs only
- `scripts/report.sh` — validate the document, assemble the envelope, optionally send
- `.github/workflows/ci.yaml` — shellcheck plus a smoke test against a real
  archfit-emitted document fetched from the engine repo

## Invariants

- **The envelope states what was analysed; it proves nothing.** Every field is
  self-reported by a job that runs pull-request code. Authoritative provenance
  is in the OIDC token claims and only the receiving service can verify them. Do
  not add a field here that reads like an attestation.
- **PR identity comes from the event payload, never from the job's context.** A
  `workflow_run`-triggered job runs the DEFAULT BRANCH's workflow definition and
  its `GITHUB_SHA` is that context, not the pull request's. Head, base, merge
  base and PR number are bound explicitly for that reason.
- **An unknown `schema_version` is refused, not forwarded.** The action carries
  `archfit.architecture-state.v1`. Forwarding another shape would make the
  receiver guess.
- **Fork pull requests cannot hold `id-token: write`**, so they have no
  authenticated upload path at all. Their reports are advisory evidence; do not
  add a fallback that makes them look enforceable.
- **The default mode sends nothing.** With no `endpoint` the envelope is written
  to a file. That is a supported mode, not a stub: the App backend is not
  generally available, and a local envelope is a normal build artifact.
- **Analyzer identity is part of the result.** The engine publishes
  `measurement.tool_versions`; the docs tell callers to pin the image by digest.
  Never suggest `:latest` in an example.

## Conventions

- Bash, `set -euo pipefail`, shellcheck-clean. `jq`/`curl`/`git` may be assumed
  (the archfit image ships them); anything else may not.
- The smoke test uses a document archfit actually emitted (a committed baseline
  from the engine repo), never a stub written to match this action's
  expectations.
- Releases are tagged `vN`; callers pin `@v1`.
