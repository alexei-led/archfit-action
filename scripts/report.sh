#!/usr/bin/env bash
# Assemble an archfit report envelope and, when an endpoint is configured, send it.
#
# The envelope binds the report to WHAT WAS ANALYSED, explicitly. It must not
# infer that from the job's own context: a `workflow_run`-triggered job runs the
# default branch's workflow definition and its GITHUB_SHA is that context, not
# the pull request's. So the PR number and the head/base SHAs are read from the
# event payload and carried as their own fields.
#
# Nothing here is a security claim. These fields are self-reported by the job,
# and the job runs code from the pull request. The authoritative provenance —
# which workflow definition ran, on which repository, at which attempt — lives
# in the OIDC token's claims, which only the receiving service can verify. This
# script's job is to state what it analysed, not to prove it.
set -euo pipefail

state_file="${ARCHFIT_STATE_FILE:-archfit-state.json}"
envelope_file="${ARCHFIT_ENVELOPE_FILE:-archfit-envelope.json}"
endpoint="${ARCHFIT_ENDPOINT:-}"
audience="${ARCHFIT_AUDIENCE:-archfit-app}"

# Schema version this action knows how to carry. A document declaring anything
# else is refused rather than forwarded: the App would have to guess its shape.
readonly SUPPORTED_SCHEMA="archfit.architecture-state.v1"

die() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required and was not found on PATH"

[[ -f "$state_file" ]] ||
  die "state file '$state_file' not found — run 'archfit check --json > $state_file' first"

schema="$(jq -r '.schema_version // ""' "$state_file")"
[[ "$schema" == "$SUPPORTED_SCHEMA" ]] ||
  die "state file declares schema_version '$schema', this action carries '$SUPPORTED_SCHEMA'"

verdict="$(jq -r '.verdict // ""' "$state_file")"
[[ -n "$verdict" ]] || die "state file declares no verdict"

# Pull-request identity from the event payload. Absent on a push build, where
# the head SHA is the commit itself and there is no base.
pr_number=""
pr_head=""
pr_base=""
if [[ -f "${GITHUB_EVENT_PATH:-}" ]]; then
  pr_number="$(jq -r '.pull_request.number // .workflow_run.pull_requests[0].number // ""' "$GITHUB_EVENT_PATH")"
  pr_head="$(jq -r '.pull_request.head.sha // .workflow_run.head_sha // ""' "$GITHUB_EVENT_PATH")"
  pr_base="$(jq -r '.pull_request.base.sha // ""' "$GITHUB_EVENT_PATH")"
fi

merge_base=""
if [[ -n "$pr_head" && -n "$pr_base" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
  # Best effort: a shallow checkout may not contain both sides. An unknown
  # merge base is reported as empty, never as one of the two SHAs.
  merge_base="$(git merge-base "$pr_base" "$pr_head" 2>/dev/null || true)"
fi

report_digest="$(shasum -a 256 "$state_file" 2>/dev/null | cut -d' ' -f1 ||
  sha256sum "$state_file" | cut -d' ' -f1)"

jq -n \
  --arg schema "archfit.report-envelope.v1" \
  --arg repository "${GITHUB_REPOSITORY:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg workflow_ref "${GITHUB_WORKFLOW_REF:-}" \
  --arg event "${GITHUB_EVENT_NAME:-}" \
  --arg pr_number "$pr_number" \
  --arg head_sha "$pr_head" \
  --arg base_sha "$pr_base" \
  --arg merge_base "$merge_base" \
  --arg report_digest "$report_digest" \
  --arg verdict "$verdict" \
  '{
    schema_version: $schema,
    repository: $repository,
    run: {id: $run_id, attempt: $run_attempt, event: $event,
          workflow_ref: $workflow_ref},
    analysed: {pull_request: $pr_number, head_sha: $head_sha,
               base_sha: $base_sha, merge_base: $merge_base},
    report: {digest: $report_digest, verdict: $verdict}
  }' > "$envelope_file"

printf 'envelope-file=%s\n' "$envelope_file" >> "${GITHUB_OUTPUT:-/dev/null}"
printf 'verdict=%s\n' "$verdict" >> "${GITHUB_OUTPUT:-/dev/null}"
printf 'archfit: verdict=%s envelope=%s\n' "$verdict" "$envelope_file"

if [[ -z "$endpoint" ]]; then
  printf '::notice::no endpoint configured — envelope written to %s, nothing sent\n' "$envelope_file"
  exit 0
fi

[[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] ||
  die "OIDC is unavailable — the job needs 'permissions: id-token: write' (fork pull requests cannot have it)"

token="$(curl -fsSL \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" | jq -r '.value')"
[[ -n "$token" && "$token" != "null" ]] || die "could not obtain an OIDC token"

# The state document rides as the body; the envelope travels as a header so the
# App can reject a mismatch before reading a report it has not accepted yet.
curl -fsS -X POST "$endpoint" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -H "X-Archfit-Envelope: $(tr -d '\n' < "$envelope_file")" \
  --data-binary "@${state_file}"
printf 'archfit: report sent to %s\n' "$endpoint"
