# Changelog

## v3.1.0

### Changed

- `engine-version` and `image-digest` are optional. Omitted, they are the engine
  this release pins: v3.4.0, `linux/amd64`
  `sha256:bdcfe29bf9def9a4f0ae544923bc3e755fdec2c2cd6c46ec353c01e60642896b` or
  `linux/arm64` `sha256:0cadc39c41de4dc58bb115b22bdd0296cb81688175a6ea1839a1e16ed2c35e1f`,
  by the runner's architecture. Given, they are checked as before.
- The README shows the minimal workflow and a Dependabot `github-actions` entry:
  one action commit bump now upgrades the engine too.

### Upgrade

- Drop `engine-version` and `image-digest` from the workflow, or keep them at
  v3.4.0 and the digest for the runner. The envelope and its schema are unchanged.

## v3.0.0

### Changed

- Pull requests are analysed as they would land. The run checks out GitHub's
  test merge commit of the head into the base, so a change that is clean alone
  but breaks the architecture once merged is measured. The head is still the
  commit approval binds to.
- The envelope gains `analyzed_sha` (the commit measured), `integration`
  (`merged` or `conflicts`) and the optional `policy_change`. Off pull requests
  `analyzed_sha` equals `head_sha` and `integration` is empty. The envelope keeps
  its version string.
- A pull request GitHub reports as conflicting is analysed as its head alone
  (`integration: conflicts`).
- The merge commit must have the event's base and head as parents, or the run
  fails before the engine starts.
- On a merged pull request, origin compares with the event's base commit. The
  merge base is used when the head is analysed alone.
- A pull request that changes `.archfit.yaml` gets the engine's classification of
  the policy change: the `archfit-policy-change` artifact, a step-summary line
  (`loosens`, `tightens`, coverage lost), and the envelope's optional
  `policy_change` field for the App. Report-only: a failure is a warning and the
  verdict is unchanged. The field is left out when the change orders nothing, and
  when it would make the envelope larger than 8192 bytes (the log warns). The
  classification comes from engine v3.4.0 (`archfit config compare`).
- Concurrency for hand-written workflows is documented in the README.

### Upgrade

- Run engine **v3.4.0** only, with its per-platform image manifest:
  `linux/amd64` `sha256:bdcfe29bf9def9a4f0ae544923bc3e755fdec2c2cd6c46ec353c01e60642896b`,
  `linux/arm64` `sha256:0cadc39c41de4dc58bb115b22bdd0296cb81688175a6ea1839a1e16ed2c35e1f`.
  Do not substitute the multi-arch index digest. Older engine versions, v3.2.3
  included, are refused before checkout. Update `engine-version` and
  `image-digest` together with the action commit.
- The App must accept the 18-key envelope with the optional `policy_change`
  (vendored schema sha256 `0c2de1a3691ac85935f04887b94bc98dbc01f57f65a9c4fc3db276d5bf78b7e6`)
  before the action reports to it. A
  pull request's verdict covers the merged tree, so it can report findings the
  target already has that are not accepted in the baseline. Origin marks the
  findings the pull request introduced.
- The action's inputs are unchanged. The engine release notes list the policy and
  baseline changes.

## v2.2.1

### Changed

- Run only Engine v3.2.3 with its verified native platform manifests. Older engine
  versions are refused before checkout.
- Qualify genuine report, baseline and reanchor outputs from the published image.
  The transport fixtures remain byte-identical to the prior captures.

### Upgrade

Update the Action commit, `engine-version: v3.2.3`, and matching platform digest
together after the App approves that tuple. Do not substitute the multiarch index
digest for the platform manifest.

Envelope, upload, gate and trusted-input behavior are unchanged. This producer
adoption does not require a policy or baseline reset; existing comparison and
required-evidence checks still apply.

## v2.2.0

### Changed

- Run engine v3.2.0 only, using its verified per-platform image manifests. Older
  engine inputs are refused before checkout. Native CI covers amd64 and arm64.
- Refresh analyzer facts for reports, baseline capture, reanchor, and self-checks.
- Trust only the mounted `/src` checkout through fixed container Git settings.
  This keeps history available when bind-mount ownership differs from the runner
  UID. Host/global Git configuration and credential isolation are unchanged.
- Replace test captures with unmodified released-image outputs and record hashes.
  Fix envelope-schema provenance to its actual unchanged App source revision.

### Fixed

- Without an App endpoint, report mode fails when required evidence is unavailable,
  hard gates do not pass, active blockers remain, or decision evidence is missing or
  malformed. Optional `needs_attention` still passes with passing hard gates and no
  unevaluated required rules. App uploads, fork handling and artifact-only discovery,
  baseline and re-anchor modes retain their existing upload behavior.

### Upgrade

1. Update the Action commit, `engine-version: v3.2.0`, and matching platform digest
   together, after the App approves that tuple. Older pins cannot run this Action.
2. Run fresh scans before reviewing a baseline migration. Changed producer semantics
   do not automatically accept debt or repair missing required evidence.

## v2.1.0

### Added

- Pull request reports carry the origin of each finding. The check runs with
  `--base <merge base>`, and the engine fills `findings[].origin` and
  `agent_tasks[].origin` (`introduced`, `pre_existing` or `unknown`),
  `comparison.origin_status`, `introduced_finding_ids` and
  `resolved_finding_ids`. Origin is report-only: the verdict and the exit code
  do not change. The step summary shows the origin status and counts. `push`
  runs are unchanged.
- For that run only, an empty `RUNNER_TEMP` directory is mounted writable over
  `/src/.git/worktrees`, so the engine can run `git worktree add`. The rest of
  `.git` stays read-only. After the run, the action deletes the worktree the
  engine leaves under `.archfit-cache/worktrees`, and refuses to follow a
  symlink there.

### Changed

- The action runs engine v3.0.1 only. Pin `engine-version: v3.0.1` and its
  per-platform `image-digest` from the App's manifest; v3.0.0 is refused. A
  v3.0.1 baseline or re-anchor no longer writes `state.dimensions` or
  `state.hard_gate_finding_ids`. The schema stays `archfit.baseline.v3`, so a
  stored v3.0.0 baseline still loads, and the next capture drops the two fields.
- A pull request run takes about two engine passes of time: one `--base` run
  analyses the head and the merge base.
- If the `--base` run ends without a report, the job does not fail for that.
  The check runs again without `--base`, from an empty `/bundle`, and the log
  warns that origin is missing for this run.

The envelope does not change: origin is in the state payload only.

## v2.0.0

Breaking. The action runs engine v3.0.0 only. No users depend on v1.x, so there
is no migration path.

### Changed

- Pin `engine-version: v3.0.0` and the v3.0.0 per-platform `image-digest` from the
  App's manifest. The action refuses any other engine version and any tag.
- The baseline is `archfit.baseline.v3`. A v2 file is accepted only as the input of a
  re-anchor; `check` refuses it.
- `mode` takes `report`, `discovery`, `baseline` or `reanchor`.
- The envelope schema is the App's revision with `kind: reanchor`.

### Removed

- The `discover` input. Use `mode: discovery`.
- Engine v2.x support, and the v2 baseline and envelope handling in hints and tests.

### Added

- `mode: reanchor`. Carries the accepted debt of the protected baseline to the
  engine v3 measurement epoch and accepts no new finding. The protected file is
  mounted read-only at `/reference/.archfit-baseline.json`. Refused before the
  engine runs when the default branch has no baseline.
- `report-file` output: the engine's re-anchor report. It is printed in the log,
  written to the step summary, and kept in the `archfit-baseline` artifact.
- The App endpoint `POST /v1/reanchors`, with `kind: reanchor` and a required
  `baseline_digest`.
