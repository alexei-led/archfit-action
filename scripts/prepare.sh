#!/usr/bin/env bash
# Validate the inputs, pick the mode and name the commit to check out.
# Runs before the checkout, so a misconfigured workflow fails before any engine work.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require jq
[[ -f ${GITHUB_EVENT_PATH:-} ]] || die "GITHUB_EVENT_PATH is not set; run this action in a GitHub Actions job"

engine_version=${ARCHFIT_ENGINE_VERSION:-}
image_digest=${ARCHFIT_IMAGE_DIGEST:-}
endpoint=${ARCHFIT_ENDPOINT:-}
mode=${ARCHFIT_MODE:-}
discover=${ARCHFIT_DISCOVER:-}

[[ $engine_version =~ ^[A-Za-z0-9._+-]{1,64}$ ]] ||
	die "engine-version '$engine_version' is not a version such as v2.3.1"
[[ $image_digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
	die "image-digest must be sha256:<64 lowercase hex>, the per-platform manifest digest of $ENGINE_IMAGE_REPO; tags are refused"
[[ -z $endpoint || $endpoint =~ ^https?://[^[:space:]]+$ ]] ||
	die "endpoint must be the App base URL, for example https://archfit.example"

# The generated workflow passes its boolean dispatch input as `discover`: "true" on a
# discovery dispatch, "false" on a plain dispatch, "" on pull_request and push.
case $discover in
true)
	[[ -z $mode || $mode == discovery ]] || die "mode '$mode' conflicts with discover: true"
	mode=discovery
	;;
'' | false) mode=${mode:-report} ;;
*) die "discover must be true or false, got '$discover'" ;;
esac
case $mode in
report | discovery | baseline) ;;
*) die "mode must be report, discovery or baseline, got '$mode'" ;;
esac

# The analysed commit comes from the event payload, never from the job context: a
# pull_request job's GITHUB_SHA is a merge commit, and a workflow_run job runs the
# default branch with that branch's GITHUB_SHA.
event=${GITHUB_EVENT_NAME:?}
# The App accepts a dispatched run only as discovery; a dispatched report would end as
# unsupported_event, so it is refused before any work.
[[ $event != workflow_dispatch || $mode != report ]] ||
	die "a workflow_dispatch run does not report: dispatch with discover: true to propose a policy, or set mode: baseline. Reports come from pull_request and push runs."
case $event in
pull_request) ref=$(event_field .pull_request.head.sha) ;;
workflow_run) ref=$(event_field .workflow_run.head_sha) ;;
*) ref=${GITHUB_SHA:?} ;;
esac
is_sha "$ref" || die "cannot tell which commit this $event event analyses (got '$ref')"

# Discovery proposes the first policy and baseline captures accepted debt; both describe
# the protected default branch, so neither runs anywhere else.
if [[ $mode != report ]]; then
	default_branch=$(event_field .repository.default_branch)
	[[ -n $default_branch && ${GITHUB_REF:-} == "refs/heads/$default_branch" ]] ||
		die "$mode mode runs on the default branch (${default_branch:-unknown}) only; this run is on ${GITHUB_REF:-an unknown ref}"
fi

work=$(work_dir)
rm -rf "$work"
mkdir -p "$work"

set_output mode "$mode"
set_output ref "$ref"
printf 'archfit: mode=%s event=%s commit=%s\n' "$mode" "$event" "$ref"
