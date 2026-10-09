# Changelog

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
