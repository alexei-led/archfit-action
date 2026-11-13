#!/usr/bin/env bash
# Write the upload envelope and send the result to the archfit App.
#
# The envelope is the App's contract: archfit.upload-envelope.v2, owned by archfit-app
# (schema/ holds the vendored copy CI validates against). It states what was checked:
# repository, event, pull request, head, merge base, the target branch and the tip the
# policy was read from, the policy digest, run, engine identity, and the digest of the
# result bytes, which are the body.
# Every field is self-reported by a job that runs pull-request code. The App binds the
# envelope to the OIDC token's claims and to GitHub's own data and trusts no field
# alone: a matching envelope is necessary for an accepted result, never sufficient.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require jq curl

# App limits: the upload body cap (gate/ingest) and the raw envelope cap (wire/envelope).
readonly REPORT_MAX_BYTES=5242880
readonly ENVELOPE_MAX_BYTES=8192
# Retries happen only when the App asks for one (429), failed (5xx), or did not answer.
readonly MAX_ATTEMPTS=5
readonly RETRY_BUDGET_SECONDS=300
readonly RETRY_AFTER_CAP_SECONDS=120

facts=${ARCHFIT_FACTS:?}
endpoint=${ARCHFIT_ENDPOINT:-}
audience=${ARCHFIT_AUDIENCE:-$endpoint}
work=$(work_dir)

fact() { jq -r ".$1" "$facts"; }
result_status=$(fact status)
payload=$(fact payload_file)
fork=$(fact fork)

[[ -n $payload ]] || exit 0 # nothing was checked; run.sh said why
[[ -f $payload ]] || die "result $payload is missing"

# envelope prints the 15 keys of archfit.upload-envelope.v2 on one line, typed as the App
# decodes them: integers for pull_request, run_id and run_attempt, sha256:-prefixed digests.
envelope() {
	local digest
	[[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]{0,18}$ ]] || die "GITHUB_RUN_ID is not a run ID"
	[[ ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]{0,8}$ ]] || die "GITHUB_RUN_ATTEMPT is not an attempt number"
	digest=$(sha256_hex "$payload") || die "cannot hash $payload"
	jq -cj \
		--arg repository "${GITHUB_REPOSITORY:?}" \
		--argjson run_id "$GITHUB_RUN_ID" \
		--argjson run_attempt "$GITHUB_RUN_ATTEMPT" \
		--arg payload_digest "sha256:$digest" \
		'{schema_version: "archfit.upload-envelope.v2", repository: $repository, event,
		  pull_request, head_sha, merge_base_sha, target_ref, target_sha, policy_digest,
		  run_id: $run_id, run_attempt: $run_attempt,
		  engine_version, image_digest, platform, payload_digest: $payload_digest}' "$facts"
}

envelope_file=$work/envelope.json
envelope >"$envelope_file"
set_output envelope-file "$envelope_file"

if [[ -z $endpoint ]]; then
	notice "no endpoint: nothing was sent; the envelope is $envelope_file"
	# Without an App this job is the gate: only a pass passes.
	case $result_status in
	pass) ;;
	fail) die "the architecture check failed. Without an App endpoint this job is the gate; the archfit-result artifact lists the errors." ;;
	*) die "the architecture check has no verdict (status $result_status). Without an App endpoint this job is the gate; the archfit-result artifact says what is unknown and what to do." ;;
	esac
	exit 0
fi

if [[ $fork == true ]]; then
	notice "fork pull request: nothing was sent. GitHub gives fork runs no OIDC token, so the App cannot authenticate the result; it marks fork pull requests fork. The result is in the archfit-result artifact. Push the branch to this repository for a gated check."
	exit 0
fi

[[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-} ]] ||
	die "no OIDC token is available: the job needs 'permissions: id-token: write'"

readonly route=/v1/reports
size=$(wc -c <"$payload" | tr -d ' ')
((size <= REPORT_MAX_BYTES)) || die "the result is $size bytes; the App accepts at most $REPORT_MAX_BYTES"
envelope_size=$(wc -c <"$envelope_file" | tr -d ' ')
((envelope_size <= ENVELOPE_MAX_BYTES)) ||
	die "the envelope is $envelope_size bytes; the App accepts at most $ENVELOPE_MAX_BYTES"
envelope_line=$(<"$envelope_file")
[[ $envelope_line != *[$'\r\n']* ]] || die "the envelope must be one line"
url=${endpoint%/}$route
answer=$work/answer.json
answer_headers=$work/answer.headers

# mint_token requests a GitHub Actions OIDC token for the App's audience. Each attempt
# mints a fresh one: tokens are short-lived and a retry can come minutes later. Tokens
# stay in this shell; headers reach curl on stdin, never in its arguments.
mint_token() {
	local response
	response=$(printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" |
		curl --silent --show-error --fail --connect-timeout 10 --max-time 30 --header @- \
			"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$(jq -rn --arg a "$audience" '$a | @uri')") || return 1
	token=$(jq -r '.value // empty' <<<"$response" 2>/dev/null) || return 1
	[[ -n $token ]] || return 1
	printf '::add-mask::%s\n' "$token"
}

# post sends one attempt and prints the HTTP status, "000" when no answer arrived.
post() {
	printf 'Authorization: Bearer %s\n' "$token" |
		curl --silent --show-error \
			--output "$answer" --dump-header "$answer_headers" --write-out '%{http_code}' \
			--connect-timeout 10 --max-time 90 \
			--header @- \
			--header "X-Archfit-Envelope: $envelope_line" \
			--header "Content-Type: application/json" \
			--data-binary @"$payload" \
			"$url" || true
}

# retry_wait ATTEMPT prints the seconds before the next attempt: the App's Retry-After
# (capped), else exponential backoff from 5 s with ±20% jitter.
retry_wait() {
	local after
	# Only delta-seconds of at most four digits; an HTTP date or any other value falls
	# back to backoff. Base 10 explicitly: "08" is not an octal error.
	after=$(awk -F': *' 'tolower($1) == "retry-after" { v = $2; sub(/[ \t\r]+$/, "", v)
		if (v ~ /^[0-9]+$/ && length(v) <= 4) r = v }
		END { print r }' "$answer_headers")
	if [[ -n $after ]]; then
		after=$((10#$after))
		printf '%s' $((after < RETRY_AFTER_CAP_SECONDS ? after : RETRY_AFTER_CAP_SECONDS))
	else
		printf '%s' $(((5 << ($1 - 1)) * (80 + RANDOM % 41) / 100))
	fi
}

deadline=$((SECONDS + RETRY_BUDGET_SECONDS))
attempt=0 status=000 token="" token_failed=false
while :; do
	attempt=$((attempt + 1))
	: >"$answer"
	: >"$answer_headers"
	if mint_token; then
		token_failed=false
		status=$(post)
	else
		token_failed=true status=000
	fi
	case $status in
	429 | 5?? | 000) ;;
	*) break ;;
	esac
	((attempt < MAX_ATTEMPTS)) || break
	wait=$(retry_wait "$attempt")
	((SECONDS + wait <= deadline)) || break
	printf 'archfit: upload attempt %d: %s; retrying in %ss\n' "$attempt" "$status" "$wait"
	sleep "$wait"
done

answer_json=$(jq -ce 'select(type == "object")' "$answer" 2>/dev/null | head -n 1) || answer_json=""
((${#answer_json} <= 4096)) || answer_json=""
set_output app-status "$status"
set_output app-answer "$answer_json"
answer_field() { [[ -z $answer_json ]] || jq -r "$1 // empty" <<<"$answer_json"; }
# app_value FILTER PATTERN prints an answer field only when it has the shape the App
# documents; anything else could carry workflow commands or markdown into the log.
app_value() {
	local value
	value=$(answer_field "$1")
	if [[ $value =~ $2 ]]; then printf '%s' "$value"; else printf '(unexpected value)'; fi
}
readonly APP_TOKEN='^[a-z_]{1,64}$'
code=$(app_value .error "$APP_TOKEN")
[[ $code != '(unexpected value)' ]] || code=""

hint() {
	case $code in
	envelope_missing | envelope_invalid) echo "Use the action commit the App pins in the generated workflow." ;;
	token_missing) echo "The job needs 'permissions: id-token: write'." ;;
	token_invalid) echo "The OIDC audience ($audience) must equal the App base URL exactly." ;;
	repository_mismatch) echo "The OIDC token and the envelope name different repositories." ;;
	not_installed) echo "Install the archfit GitHub App on this repository." ;;
	installation_not_approved) echo "The App does not admit this installation yet." ;;
	workflow_path) echo "Run archfit from .github/workflows/archfit.yaml as that workflow's own job, not as a reusable workflow." ;;
	run_not_found | run_mismatch) echo "Run the workflow again." ;;
	payload_too_large) echo "The result exceeds the App's size limit." ;;
	rate_limited | unavailable | oidc_unavailable | admission_unavailable | internal) echo "The App is unavailable; run the workflow again later." ;;
	method_not_allowed) echo "A proxy changed the request method; endpoint must be the App base URL, reached directly." ;;
	*)
		case $status in
		404 | 405) echo "endpoint must be the App base URL; the action appends $route." ;;
		*) echo "The App's answer: ${answer_json:-none}." ;;
		esac
		;;
	esac
}

case $status in
2??)
	# "accepted", not "passed": the App's check carries the status it gives the result.
	result="status $(app_value .status '^(pass|fail|waiting|unknown)$')"
	reason=$(answer_field .reason)
	[[ -z $reason ]] || result+=", reason $(app_value .reason "$APP_TOKEN")"
	printf 'archfit: the App accepted the result: %s\n' "$(escape "$result")"
	summary "- App: accepted the result ($status): $result. The App's check carries the status; this job's status covers only the upload."
	;;
409)
	# A newer run of the same head, a head that moved, or a merge group the queue no longer
	# lists: the newer run uploads its own result, and nothing is published for this one.
	notice "the App answered 409 ${code:-conflict}: a newer run, head or merge group supersedes this upload, and nothing was published for it"
	;;
000)
	summary "- App: no answer for the upload after $attempt attempt(s)."
	[[ $token_failed == false ]] || die "could not obtain an OIDC token for audience $audience after $attempt attempts"
	die "no answer from $url after $attempt attempts"
	;;
*)
	summary "- App: refused the upload: HTTP $status${code:+ $code} after $attempt attempt(s)."
	die "the App did not accept the upload: HTTP $status${code:+ $code} after $attempt attempt(s). $(hint)"
	;;
esac
