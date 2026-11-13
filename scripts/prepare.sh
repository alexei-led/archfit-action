#!/usr/bin/env bash
# Validate the inputs and name the commit to check out.
# Runs before the checkout, so a misconfigured workflow fails before any engine work.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require jq
[[ -f ${GITHUB_EVENT_PATH:-} ]] || die "GITHUB_EVENT_PATH is not set; run this action in a GitHub Actions job"

# An omitted engine-version or image-digest means the engine this action release pins,
# so a consumer upgrades engine and action with one commit bump. A given one is checked
# as before.
engine_version=${ARCHFIT_ENGINE_VERSION:-$SUPPORTED_ENGINE_VERSION}
image_digest=${ARCHFIT_IMAGE_DIGEST:-}
if [[ -z $image_digest ]]; then
	case ${RUNNER_ARCH:-} in
	X64) image_digest=$ENGINE_DIGEST_AMD64 ;;
	ARM64) image_digest=$ENGINE_DIGEST_ARM64 ;;
	*) die "runner architecture '${RUNNER_ARCH:-unset}' has no engine image (X64, ARM64); set image-digest only if the App's manifest lists one for it" ;;
	esac
fi
endpoint=${ARCHFIT_ENDPOINT:-}
mode=${ARCHFIT_MODE:-report}

[[ $engine_version =~ ^[A-Za-z0-9._+-]{1,64}$ ]] ||
	die "engine-version '$engine_version' is not a version such as $SUPPORTED_ENGINE_VERSION"
# This action runs one engine: the App's manifest, the envelope schema and the result
# contract are its. Another image is refused here, not adapted.
[[ $engine_version == "$SUPPORTED_ENGINE_VERSION" ]] ||
	die "engine-version '$engine_version' is not supported: this action runs engine $SUPPORTED_ENGINE_VERSION only; pin $SUPPORTED_ENGINE_VERSION and its digest"
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

[[ $mode == report ]] ||
	die "mode '$mode' is not supported: Action 4 only checks pull_request, push and merge_group runs; remove the mode input"

# Only the events the App accepts. The others are refused before the checkout:
# workflow_run and pull_request_target run with the base repository's privileges on a
# commit the pull request author controls, and a dispatched run has no change to check.
event=${GITHUB_EVENT_NAME:?}
case $event in
pull_request | push | merge_group) ;;
*) die "archfit runs on pull_request, push and merge_group events only; '$event' is refused before the checkout. Trigger the archfit workflow with one of those events." ;;
esac
# The checked commit is tied to the event payload. A pull request is checked at its head,
# the commit the App binds the result to. A merge group is checked at the group's own commit.
case $event in
pull_request) ref=$(event_field .pull_request.head.sha) ;;
merge_group)
	# Only the queue of the default branch: the App's protected inputs and approvals are
	# the default branch's, and no other branch gains trust here. The job context only
	# locates the group commit; the event names it. The queue branch's name proves
	# nothing and is not read.
	[[ $(event_field .action) == checks_requested ]] ||
		die "merge_group action '$(event_field .action)' is not checks_requested; nothing is checked"
	default_branch=$(event_field .repository.default_branch)
	[[ -n $default_branch && $(event_field .merge_group.base_ref) == "refs/heads/$default_branch" ]] ||
		die "this merge group targets '$(event_field .merge_group.base_ref)'; archfit gates the merge queue of the default branch (${default_branch:-unknown}) only"
	ref=$(event_field .merge_group.head_sha)
	is_sha "$(event_field .merge_group.base_sha)" || die "the merge_group event carries no base SHA"
	[[ ${GITHUB_SHA:-} == "$ref" && ${GITHUB_REF:-} == "$(event_field .merge_group.head_ref)" ]] ||
		die "the job runs at ${GITHUB_REF:-an unknown ref} ${GITHUB_SHA:-} but the merge_group event names $(event_field .merge_group.head_ref) $ref; run archfit in the job the merge_group event started"
	;;
push)
	# A push is checked against the branch it updates; a tag has no target branch.
	[[ ${GITHUB_REF:-} == refs/heads/?* ]] ||
		die "this push updates ${GITHUB_REF:-an unknown ref}, not a branch; archfit checks pushes to branches only"
	ref=${GITHUB_SHA:?}
	;;
esac
is_sha "$ref" || die "cannot tell which commit this $event event checks (got '$ref')"

work=$(work_dir)
rm -rf "$work"
mkdir -p "$work"

set_output engine-version "$engine_version"
set_output image-digest "$image_digest"
set_output ref "$ref"
printf 'archfit: event=%s commit=%s\n' "$event" "$ref"
