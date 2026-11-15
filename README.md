# archfit-action

Run [archfit](https://github.com/alexei-led/archfit) on your GitHub Actions
runner and send the result to the archfit GitHub App. The Action checks a change
once with the policy from the target branch. The App receives the result; it does
not run the engine on your code.

## Workflow

The App or `archfit init` can prepare the workflow. Place it at
`.github/workflows/archfit.yaml` so the App can identify it:

```yaml
name: archfit
on:
  pull_request:
  push:
    branches: [main]
  merge_group:
    types: [checks_requested]

permissions:
  contents: read
  id-token: write

jobs:
  archfit:
    runs-on: ubuntu-latest
    steps:
      - uses: alexei-led/archfit-action@<40-hex-commit> # v4.0.0
        with:
          endpoint: https://archfit.example
          audience: https://archfit.example
```

Replace `main`, the endpoint, and the Action placeholder with the values for your
installation. Use a full Action commit listed in the App manifest. The Action
checks out the change itself without persisting credentials. The job needs
`id-token: write` to upload; fork pull requests cannot receive that permission,
so their results are artifacts only and are not enforceable by the App.

The endpoint is the App base URL over HTTPS with no trailing slash. The audience
must equal that URL; omit `audience` to use the endpoint. HTTP is accepted only
for `localhost` or `127.0.0.1`. Without `endpoint`, no result is sent and the job
itself fails on `fail` or `unknown`.

The Action pins one engine release and a per-platform image digest for X64 and
ARM64. `engine-version` and `image-digest` are optional; if supplied, the version
must match the supported engine and the digest must name the correct image and
platform in the App manifest. Image tags are not accepted. Upgrade the Action
commit only after the App lists it and the engine digests.

## Protect the default branch

Configure a branch ruleset that requires pull requests, has zero required GitHub
approvals, and requires `archfit/gate` from the archfit App. Do not make the App a
bypass actor. Owners approve policy requests in the App; an administrator bypass
is an emergency path, not an archfit pass. On eligible organization-owned private
or internal repositories, a push ruleset can restrict the policy path as additional
protection. Check the App's setup guidance for its availability.

## What the check does

- It accepts `pull_request`, branch `push`, and default-branch `merge_group`
  (`checks_requested`). Other events, including `workflow_dispatch`,
  `workflow_run` and `pull_request_target`, are refused before checkout.
- It checks the pull request head, pushed commit, or merge group commit. It
  fetches the target branch at the start of each run, including re-runs.
- If the change leaves `.archfit.yaml` unchanged and its commit is not the
  target tip, the engine reads the target tip's policy blob. If the change edits
  the policy, the engine compares it with the target policy; a difference is
  `unknown`. A check at the target tip uses the checkout's policy and can also be
  `unknown` if checkout rules change its bytes. If the change deletes the policy,
  the Action produces an `unknown` result. If neither target nor change has a
  policy, nothing is checked or sent.
- It saves `archfit-result`, the JSON result artifact, before upload. The App
  receives the same bytes with its envelope 2 and decides the `archfit/gate`
  check. A successful upload is not necessarily a passing check. The engine
  statuses are `pass`, `fail`, and `unknown`; the App can also show `waiting`.
- It checks the image version and platform before analysis. It does not forward
  credentials to the container. The checkout's `.git` and target policy copy are
  read-only; an isolated cache prevents the change from supplying cached facts.

The envelope's identity and digest fields are self-reported claims, not an
attestation. The App checks them against its manifest and GitHub data.

## Action outputs

| Output | Meaning |
| --- | --- |
| `verdict` | Engine status: `pass`, `fail`, or `unknown`; empty when nothing was checked. |
| `envelope-file` | Path to the envelope written by the report step. |
| `app-status` | Final App HTTP status, or `000` when no answer arrived. |
| `app-answer` | App JSON answer on one line. |

For details and errors, read the job summary and `archfit-result` artifact.
