# Changelog

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
