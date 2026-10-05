#!/usr/bin/env bash
# Write the report envelope and send the payload to the archfit App.
#
# The envelope is the App's contract: archfit.report-envelope.v1, owned by archfit-app
# (schema/ holds the vendored copy CI validates against). It states what was analysed:
# repository, event, pull request, head, base and merge base, run, engine identity, and
# the digests of the payload and of the baseline and labels files the engine read.
# Every field is self-reported by a job that runs pull-request code. The App binds the
# envelope to the OIDC token's claims and to GitHub's own data and trusts no field
# alone: a matching envelope is necessary for an accepted report, never sufficient.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require jq curl

# App limits: the upload body cap (wire/report MaxBytes), the discovery draft cap
# (control/onboarding), the baseline file cap (wire/policy MaxBaselineBytes), and the
# raw envelope cap (wire/envelope).
readonly REPORT_MAX_BYTES=5242880
readonly DISCOVERY_MAX_BYTES=1048576
readonly BASELINE_MAX_BYTES=1048576
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
mode=$(fact mode)
kind=$(fact kind)
verdict=$(fact verdict)
payload=$(fact payload_file)
fork=$(fact fork)

# Without an App the capture stays an artifact: nobody would open its pull request.
if [[ $mode == baseline && -z $endpoint ]]; then
	notice "baseline captured and comparable in this image. Commit the archfit-baseline artifact as .archfit-baseline.json in a pull request that a policy owner approves."
	summary "Baseline: the \`archfit-baseline\` artifact holds \`.archfit-baseline.json\`. Commit it in a pull request that a policy owner approves."
	exit 0
fi
[[ -n $kind ]] || exit 0 # nothing was measured; run.sh said why
[[ -f $payload ]] || die "payload $payload is missing"

# envelope prints the 16 keys of archfit.report-envelope.v1 on one line, typed as the
# App decodes them: integers for pull_request, run_id and run_attempt, sha256:-prefixed
# payload and image digests, bare hex input digests ("" = the engine read no such file).
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
		'{schema_version: "archfit.report-envelope.v1", kind, repository: $repository, event,
		  pull_request, head_sha, base_sha, merge_base_sha,
		  run_id: $run_id, run_attempt: $run_attempt,
		  engine_version, image_digest, platform,
		  payload_digest: $payload_digest, baseline_digest, labels_digest}' "$facts"
}

envelope_file=$work/envelope.json
envelope >"$envelope_file"
set_output envelope-file "$envelope_file"

if [[ -z $endpoint ]]; then
	notice "no endpoint: nothing was sent; the envelope is $envelope_file"
	[[ $kind != report || $verdict != blocked ]] ||
		die "the architecture verdict is blocked. Without an App endpoint this job is the gate; the archfit-report artifact lists the blocking findings."
	exit 0
fi

if [[ $fork == true ]]; then
	notice "fork pull request: nothing was sent. GitHub gives fork runs no OIDC token, so the App cannot authenticate the report; it marks fork pull requests fork_unsupported. The report is in the archfit-report artifact. Push the branch to this repository for a gated report."
	exit 0
fi

[[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-} ]] ||
	die "no OIDC token is available: the job needs 'permissions: id-token: write'"

case $kind in
report) route=/v1/reports content_type=application/json cap=$REPORT_MAX_BYTES ;;
discovery) route=/v1/discoveries content_type=application/yaml cap=$DISCOVERY_MAX_BYTES ;;
baseline) route=/v1/baselines content_type=application/json cap=$BASELINE_MAX_BYTES ;;
*) die "unknown upload kind '$kind'" ;;
esac
size=$(wc -c <"$payload" | tr -d ' ')
((size <= cap)) || die "the $kind payload is $size bytes; the App accepts at most $cap"
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
			--header "Content-Type: $content_type" \
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
	envelope_missing | envelope_invalid | kind_mismatch) echo "Use the action commit the App pins in the generated workflow." ;;
	token_missing) echo "The job needs 'permissions: id-token: write'." ;;
	token_invalid) echo "The OIDC audience ($audience) must equal the App base URL exactly." ;;
	repository_mismatch) echo "The OIDC token and the envelope name different repositories." ;;
	not_installed) echo "Install the archfit GitHub App on this repository." ;;
	run_not_found | run_mismatch | digest_mismatch) echo "Run the workflow again." ;;
	payload_too_large | discovery_too_large | baseline_too_large) echo "The payload exceeds the App's size limit." ;;
	settings_missing) echo "Merge the onboarding pull request that adds .archfit-app.yaml first." ;;
	workflow_not_approved) echo "Run $kind from the workflow that .archfit-app.yaml names." ;;
	not_default_branch | unsupported_event | envelope_mismatch | fork)
		if [[ $kind == report ]]; then
			echo "Reports come from pull_request and push runs of this repository."
		else
			echo "Run $kind by workflow_dispatch on the default branch of this repository."
		fi
		;;
	discovery_invalid) echo "The App refused the engine's draft policy." ;;
	baseline_invalid) echo "The App refused the captured file as an archfit.baseline.v2 baseline." ;;
	unknown_engine_identity) echo "Pin the engine-version and image-digest the App's manifest lists for this runner, as the generated workflow does." ;;
	policy_missing) echo "The default branch has no .archfit.yaml; merge a policy before capturing a baseline." ;;
	policy_mismatch | labels_mismatch)
		echo "The capture did not read the .archfit.yaml and .archfit-labels.yaml at the default-branch head; dispatch the baseline capture again."
		;;
	rate_limited | unavailable | oidc_unavailable | internal) echo "The App is unavailable; run the workflow again later." ;;
	method_not_allowed) echo "A proxy changed the request method; endpoint must be the App base URL, reached directly." ;;
	*)
		case $status in
		404 | 405) echo "endpoint must be the App base URL; the action appends $route." ;;
		*) echo "The App's answer: ${answer_json:-none}." ;;
		esac
		;;
	esac
}

# proposal prints the pull request the App opened or updated, shape-checked.
proposal() {
	printf 'pull request #%s %s' "$(app_value .pull_request '^[1-9][0-9]{0,9}$')" \
		"$(app_value .url '^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$')"
}

case $status in
2??)
	case $kind in
	report)
		result="conclusion $(app_value .conclusion "$APP_TOKEN"), reason $(app_value .reason "$APP_TOKEN")"
		next="The App's checks carry the verdict; this job's status covers only the upload."
		;;
	discovery)
		result="policy $(proposal)"
		next="Review and merge it to adopt the policy."
		;;
	baseline)
		# Only the JSON literal true; anything else is read as a proposal and shape-checked.
		if [[ -n $answer_json ]] && jq -e '.unchanged == true' <<<"$answer_json" >/dev/null; then
			result="unchanged: the capture equals the baseline on the default branch"
			next="Nothing was written."
		else
			result="baseline $(proposal)"
			next="The baseline changes only when an architecture owner approves that pull request's exact head commit and it is merged."
		fi
		;;
	esac
	printf 'archfit: the App accepted the %s: %s\n' "$kind" "$(escape "$result")"
	summary "- App: accepted the $kind ($status): $result. $next"
	;;
409)
	# A superseded report or draft is replaced by the newer run's own upload. A superseded
	# baseline is not: nothing proposes it until someone dispatches the capture again.
	if [[ $kind == baseline ]]; then
		summary "- App: refused the baseline (409${code:+ $code}): no pull request was opened. Dispatch the baseline capture again."
		die "the App answered 409 ${code:-conflict}: the default branch moved on or a newer run attempt exists, so no baseline pull request was opened. Dispatch the baseline capture again on the current default-branch head."
	fi
	notice "the App answered 409 ${code:-conflict}: a newer commit or run attempt supersedes this upload, and nothing was published for it"
	;;
000)
	summary "- App: no answer for the $kind upload after $attempt attempt(s)."
	[[ $token_failed == false ]] || die "could not obtain an OIDC token for audience $audience after $attempt attempts"
	die "no answer from $url after $attempt attempts"
	;;
*)
	summary "- App: refused the $kind upload: HTTP $status${code:+ $code} after $attempt attempt(s)."
	die "the App did not accept the $kind upload: HTTP $status${code:+ $code} after $attempt attempt(s). $(hint)"
	;;
esac
