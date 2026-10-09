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
	die "engine-version '$engine_version' is not a version such as v3.0.0"
[[ $image_digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
	die "image-digest must be sha256:<64 lowercase hex>, the per-platform manifest digest of $ENGINE_IMAGE_REPO; tags are refused"
# The endpoint doubles as the OIDC audience, which the App compares byte for byte with
# its base URL; a trailing slash would make the audience and the upload URL disagree.
# Plain http only reaches a loopback App, as in tests: the upload carries a bearer token.
https_url='^https://[^[:space:]/?#@]+(/[^[:space:]?#]*)?$'
loopback_url='^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/[^[:space:]?#]*)?$'
if [[ -n $endpoint ]]; then
	[[ $endpoint =~ $https_url || $endpoint =~ $loopback_url ]] ||
		die "endpoint must be the App base URL over https, for example https://archfit.example (http only for 127.0.0.1 or localhost)"
	[[ $endpoint != */ ]] || die "endpoint must not end with '/'; give the App base URL exactly, for example https://archfit.example"
fi

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

# Only the events the App accepts. The others are refused before the checkout:
# workflow_run and pull_request_target run with the base repository's privileges on a
# commit the pull request author controls, and merge_group has no pull request whose
# policy owners approved the inputs. The App answers unsupported_event for all of them.
event=${GITHUB_EVENT_NAME:?}
case $event in
pull_request | push | workflow_dispatch) ;;
*) die "archfit runs on pull_request, push and workflow_dispatch events only; '$event' is refused before the checkout. Trigger the archfit workflow with one of those events." ;;
esac
# The App accepts a dispatched run only as discovery or baseline; a dispatched report would end as
# unsupported_event, so it is refused before any work.
[[ $event != workflow_dispatch || $mode != report ]] ||
	die "a workflow_dispatch run does not report: dispatch with discover: true to propose a policy, or set mode: baseline. Reports come from pull_request and push runs."
# The analysed commit comes from the event payload, never from the job context: a
# pull_request job's GITHUB_SHA is a merge commit.
case $event in
pull_request) ref=$(event_field .pull_request.head.sha) ;;
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
