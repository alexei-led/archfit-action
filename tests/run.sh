#!/usr/bin/env bash
# Conformance and behaviour tests for the action's scripts.
#
# The shipped scripts run unchanged, in action.yml order (prepare, checkout, run,
# report), against scratch git repositories and recorded event payloads. Only the
# process and network boundaries are faked: a docker shim stands in for the engine
# image and replays a real archfit state document, a local server plays the App and
# the OIDC token service, and a no-op sleep replaces the backoff clock. Every
# envelope the scripts write is validated against the vendored App schema, and
# known-bad envelopes must fail the same validator.
#
# Needs bash, git, jq, curl, python3 and go, plus ARCHFIT_TEST_STATE: a real
# archfit.architecture-state.v1 document (CI fetches one pinned by commit and sha256).
# shellcheck disable=SC2016 # single-quoted $names are jq's
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

state_doc=${ARCHFIT_TEST_STATE:?set ARCHFIT_TEST_STATE to a real archfit.architecture-state.v1 document}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/archfit-action-tests.XXXXXX")
app_pid=""
stop_app() {
	[[ -n $app_pid ]] || return 0
	kill "$app_pid" 2>/dev/null || true
	wait "$app_pid" 2>/dev/null || true
	app_pid=""
}
trap 'stop_app; rm -rf "$tmp"' EXIT

schema=$root/schema/envelope.v1.schema.json
validator=$tmp/validate
build_validator "$validator"

# Fakes on PATH: the engine image and the backoff clock.
mkdir -p "$tmp/bin"
cp "$root/tests/fakes/docker" "$tmp/bin/docker"
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SLEEP_LOG:-/dev/null}"
EOF
chmod +x "$tmp/bin/docker" "$tmp/bin/sleep"
export PATH=$tmp/bin:$PATH

# Fixture: main (c1) holds code, policy, baseline and labels; feature (f1) branches
# from c1 and edits the policy; main then moves on (c2) and edits only the labels.
# YAML checks out with CRLF line ends, so working-tree bytes differ from blob bytes.
origin=$tmp/origin
git init --quiet -b main "$origin"
write_module "$origin"
printf '*.yaml text eol=crlf\n' >"$origin/.gitattributes"
printf '{"schema_version":"archfit.baseline.v2","accepted":[]}\n' >"$origin/.archfit-baseline.json"
printf 'labels: []\n' >"$origin/.archfit-labels.yaml"
commit_all "$origin" "code, policy, baseline and labels"
c1=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet -b feature
printf '# candidate policy\n' >>"$origin/.archfit.yaml"
printf '\n// Twice calls b twice.\nfunc Twice() string { return b.Hello() + b.Hello() }\n' >>"$origin/pkg/a/a.go"
commit_all "$origin" "feature: candidate policy"
f1=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet main
printf 'labels: []\n# moved on main\n' >"$origin/.archfit-labels.yaml"
commit_all "$origin" "main: labels"
c2=$(git -C "$origin" rev-parse HEAD)

no_policy=$tmp/no-policy
git init --quiet -b main "$no_policy"
write_module "$no_policy"
rm "$no_policy/.archfit.yaml"
commit_all "$no_policy" "code without a policy"
np=$(git -C "$no_policy" rev-parse HEAD)

draft=$tmp/draft.yaml
git -C "$origin" show "$c1:.archfit.yaml" >"$draft"

# From here a failing check is recorded, not fatal.
set +e

begin() { # NAME
	stop_app
	new_case "$1"
	export FAKE_DOCKER_LOG=$case_dir/docker.log FAKE_SLEEP_LOG=$case_dir/sleep.log
	export FAKE_STATE=$state_doc FAKE_DRAFT=$draft
	unset FAKE_CHECK_RC FAKE_ENGINE_VERSION FAKE_PLATFORM FAKE_BASELINE_COMPARABLE
	: >"$FAKE_DOCKER_LOG"
	: >"$FAKE_SLEEP_LOG"
}

start_app() { # ANSWERS: JSON list, one answer per upload
	local i port
	printf '%s\n' "$1" >"$case_dir/answers.json"
	python3 "$root/tests/fakes/app.py" "$case_dir/answers.json" "$case_dir/app.log" "$case_dir/app.port" &
	app_pid=$!
	for ((i = 0; i < 100; i++)); do
		[[ -s $case_dir/app.port ]] && break
		/bin/sleep 0.05
	done
	port=$(<"$case_dir/app.port")
	export ARCHFIT_ENDPOINT=http://127.0.0.1:$port
	export ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token?api-version=2.0"
	export ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
}

requests() { # KIND: how many requests of KIND (upload|token) the App saw
	if [[ -f $case_dir/app.log ]]; then
		jq -s --arg k "$1" 'map(select(.kind == $k)) | length' "$case_dir/app.log"
	else
		echo 0
	fi
}
upload_field() { jq -rs --argjson n "$1" "map(select(.kind == \"upload\"))[\$n] | $2" "$case_dir/app.log"; }
token_query() { jq -rs 'map(select(.kind == "token"))[0].query' "$case_dir/app.log"; }
engine_calls() { jq -s 'map(select(.command == "run")) | length' "$FAKE_DOCKER_LOG"; }
engine_call() { jq -cs --arg a "$1" 'map(select(.command == "run" and .args[0] == $a))[0]' "$FAKE_DOCKER_LOG"; }
json_ok() { jq -e "$1" "${@:3}" <<<"$2" >/dev/null; } # FILTER JSON [JQ ARGS]
valid_envelope() { "$validator" "$schema" "$1=$2" >"$case_dir/validator.out" 2>&1; }
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
ok_answer='{"status": 200, "body": {"conclusion": "success", "reason": "healthy"}}'

# --- Contract provenance -----------------------------------------------------------

begin "vendored schema matches SCHEMA_SOURCE"
expect_eq "schema/envelope.v1.schema.json sha256" \
	"$(sed -n 's/^sha256: //p' "$root/schema/SCHEMA_SOURCE")" "$(sha_of "$schema")"

# --- Envelopes per event, produced by the shipped scripts ----------------------------

begin "pull_request report: per-file trusted inputs, envelope and upload"
on_pull_request "$f1" "$c1"
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
envelope=$(out envelope-file) payload=$(out payload-file)
expect "the envelope conforms to the App schema" valid_envelope "$envelope" "$payload"
cp "$envelope" "$tmp/pull_request.envelope"
expect_eq "kind" report "$(envelope_field kind)"
expect_eq "event" pull_request "$(envelope_field event)"
expect_eq "pull request number" 42 "$(envelope_field pull_request)"
expect_eq "head_sha is the pull request head, not GITHUB_SHA" "$f1" "$(envelope_field head_sha)"
expect_eq "base_sha is the event's base.sha" "$c1" "$(envelope_field base_sha)"
expect_eq "merge_base_sha" "$c1" "$(envelope_field merge_base_sha)"
expect_eq "run_id is an integer" number "$(jq -r '.run_id | type' "$envelope")"
expect_eq "engine identity" "v2.3.1 $ENGINE_DIGEST linux/amd64" \
	"$(envelope_field engine_version) $(envelope_field image_digest) $(envelope_field platform)"
check_call=$(engine_call check)
expect_eq "the engine reads the policy the pull request changes from its head" \
	"$(blob_sha256 "$origin" "$f1:.archfit.yaml")" "$(jq -r '.bundle[".archfit.yaml"]' <<<"$check_call")"
expect_eq "labels changed only on main come from the base tip" \
	"$(blob_sha256 "$origin" "$c2:.archfit-labels.yaml")" "$(envelope_field labels_digest)"
expect_eq "baseline digest is the digest of the bytes the engine read" \
	"$(jq -r '.bundle[".archfit-baseline.json"]' <<<"$check_call")" "$(envelope_field baseline_digest)"
expect_eq "labels digest is the digest of the bytes the engine read" \
	"$(jq -r '.bundle[".archfit-labels.yaml"]' <<<"$check_call")" "$(envelope_field labels_digest)"
expect "the checkout has CRLF labels (fixture sanity)" grep -q $'\r' "$GITHUB_WORKSPACE/.archfit-labels.yaml"
expect "digests are of git blobs, not of CRLF working-tree files" \
	test "$(sha_of "$GITHUB_WORKSPACE/.archfit-labels.yaml")" != "$(envelope_field labels_digest)"
expect_eq "one upload" 1 "$(requests upload)"
expect_eq "route" /v1/reports "$(upload_field 0 .path)"
expect_eq "the header carries the envelope file byte for byte" "$(<"$envelope")" "$(upload_field 0 .envelope)"
expect_eq "the body is the payload the envelope digests" \
	"$(envelope_field payload_digest)" "sha256:$(upload_field 0 .body_sha256)"
expect_eq "content type" application/json "$(upload_field 0 .content_type)"
expect_eq "authorization is the minted OIDC token" "Bearer oidc-1" "$(upload_field 0 .authorization)"
expect_eq "the token audience is the endpoint, URL-encoded" \
	"api-version=2.0&audience=$(jq -rn --arg a "$ARCHFIT_ENDPOINT" '$a | @uri')" "$(token_query)"
expect_eq "app-status" 200 "$(out app-status)"
expect_eq "app-answer" '{"conclusion":"success","reason":"healthy"}' "$(out app-answer)"
expect_eq "verdict" blocked "$(out verdict)"
expect_eq "artifact name the App's graph view reads" archfit-report "$(out artifact-name)"
expect "the step summary lists the trusted inputs" grep -q 'Trusted input' "$GITHUB_STEP_SUMMARY"
options=$(jq -c .options <<<"$check_call")
expect "container runs as the workspace owner" \
	json_ok 'index("--user") as $i | .[$i + 1] == $u' "$options" --arg u "$(id -u):$(id -g)"
expect "container gets HOME=/tmp and no other variable" \
	json_ok '[range(length) as $i | select(.[$i] == "--env" or .[$i] == "-e") | .[$i + 1]] == ["HOME=/tmp"]' "$options"
expect "no env file" json_ok 'index("--env-file") == null' "$options"
expect "no token or OIDC variable reaches the container" \
	json_ok '[.options[], .args[]] | map(select(test("ACTIONS_|TOKEN"))) == []' "$check_call"
expect ".git is mounted read-only" json_ok 'index($g) != null' "$options" --arg g "$GITHUB_WORKSPACE/.git:/src/.git:ro"
expect "the image is pinned by digest and never pulled implicitly" \
	json_ok '.image == $i and (.options | index("never")) != null' "$check_call" \
	--arg i "ghcr.io/alexei-led/archfit@$ENGINE_DIGEST"
expect "engine arguments" json_ok \
	'.args == ["check", "--json", "--progress=none", "-c", "/bundle/.archfit.yaml", "--root", "/src"]' "$check_call"

begin "push report: trusted inputs from the pushed commit"
on_push "$c2"
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect_eq "pull_request, base and merge base are empty off pull requests" "0||" \
	"$(envelope_field pull_request)|$(envelope_field base_sha)|$(envelope_field merge_base_sha)"
expect_eq "head_sha is the pushed commit" "$c2" "$(envelope_field head_sha)"
expect_eq "the policy comes from the pushed commit" \
	"$(blob_sha256 "$origin" "$c2:.archfit.yaml")" "$(engine_call check | jq -r '.bundle[".archfit.yaml"]')"

begin "workflow_dispatch discovery: draft policy to /v1/discoveries"
on_dispatch "$c2" true
start_app '[{"status": 200, "body": {"pull_request": 7, "url": "https://github.com/acme/shop/pull/7"}}]'
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect_eq "kind" discovery "$(envelope_field kind)"
expect_eq "no input digests on discovery" "|" "$(envelope_field baseline_digest)|$(envelope_field labels_digest)"
expect "no trusted input reaches discovery" json_ok '.bundle == {}' "$(engine_call config)"
expect "engine arguments" json_ok '.args == ["config", "init", "--root", "/src", "--output", "-"]' "$(engine_call config)"
expect_eq "route" /v1/discoveries "$(upload_field 0 .path)"
expect_eq "content type" application/yaml "$(upload_field 0 .content_type)"
expect_eq "the body is the engine's draft" "$(sha_of "$draft")" "$(upload_field 0 .body_sha256)"
expect_eq "app-answer" '{"pull_request":7,"url":"https://github.com/acme/shop/pull/7"}' "$(out app-answer)"
expect_eq "artifact name" archfit-policy "$(out artifact-name)"

begin "workflow_run report: an honest envelope for an event the App does not support"
on_workflow_run "$f1" "$c2"
start_app '[{"status": 200, "body": {"conclusion": "action_required", "reason": "unsupported_event"}}]'
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect_eq "event" workflow_run "$(envelope_field event)"
expect_eq "head_sha is the triggering run's head, not GITHUB_SHA" "$f1" "$(envelope_field head_sha)"
expect_eq "no pull request fields" "0||" \
	"$(envelope_field pull_request)|$(envelope_field base_sha)|$(envelope_field merge_base_sha)"
expect_eq "trusted inputs come from the default branch, not the analysed head" \
	"$(blob_sha256 "$origin" "$c2:.archfit.yaml")" "$(engine_call check | jq -r '.bundle[".archfit.yaml"]')"

# --- The validator itself: it must reject what the App's decoder rejects --------------

begin "the validator rejects envelopes the App's decoder or the header transport would reject"
reference=$tmp/pull_request.envelope
expect "the reference envelope is valid" valid_envelope "$reference" ""
rejects() { # NAME: $case_dir/NAME.json must fail validation
	if "$validator" "$schema" "$case_dir/$1.json" >/dev/null 2>&1; then fail "rejects $1"; else pass "rejects $1"; fi
}
mutate() { # NAME JQ-FILTER
	jq -cj "$2" "$reference" >"$case_dir/$1.json"
	rejects "$1"
}
edit() { # NAME FROM TO: textual mutations jq cannot express
	local text
	text=$(<"$reference")
	printf '%s' "${text/"$2"/"$3"}" >"$case_dir/$1.json"
	rejects "$1"
}
mutate extra-key '. + {workflow_ref: "acme/shop/.github/workflows/archfit.yaml@refs/heads/main"}'
mutate missing-key 'del(.labels_digest)'
mutate null-kind '.kind = null'
mutate unknown-kind '.kind = "baseline"'
mutate other-schema-version '.schema_version = "archfit.report-envelope.v2"'
mutate string-run-id '.run_id |= tostring'
mutate zero-attempt '.run_attempt = 0'
mutate bare-payload-digest '.payload_digest |= ltrimstr("sha256:")'
mutate prefixed-baseline-digest '.baseline_digest = "sha256:" + ("5b" * 32)'
mutate uppercase-head '.head_sha |= ascii_upcase'
mutate platform-without-arch '.platform = "linux"'
mutate push-with-pull-request '.event = "push" | .base_sha = "" | .merge_base_sha = ""'
mutate pull-request-without-merge-base '.merge_base_sha = ""'
mutate discovery-with-baseline '.kind = "discovery" | .baseline_digest = ("5b" * 32) | .labels_digest = ""'
edit exponent-run-id '"run_id":17654321098' '"run_id":1.7654321098e10'
edit fraction-attempt '"run_attempt":1,' '"run_attempt":1.0,'
edit duplicate-key '"labels_digest"' "\"head_sha\":\"$f1\",\"labels_digest\""
edit two-lines ',"event"' $',\n"event"'
edit oversized '"}' "\"$(printf '%9000s' '')}"
expect "rejects a payload the digest does not name" \
	bash -c '! "$1" "$2" "$3=$4" >/dev/null 2>&1' _ "$validator" "$schema" "$reference" "$draft"

# --- Transport ------------------------------------------------------------------------

begin "503 with Retry-After: retried with a fresh token"
on_push "$c2"
start_app '[{"status": 503, "headers": {"Retry-After": "7"}, "body": {"error": "rate_limited"}}, '"$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "two uploads" 2 "$(requests upload)"
expect_eq "two tokens" 2 "$(requests token)"
expect_eq "the retry carries a fresh token" "Bearer oidc-2" "$(upload_field 1 .authorization)"
expect_eq "waits Retry-After" 7 "$(<"$FAKE_SLEEP_LOG")"
expect_eq "app-status is the final answer" 200 "$(out app-status)"

begin "429 without Retry-After: exponential backoff"
on_push "$c2"
start_app '[{"status": 429, "body": {"error": "rate_limited"}}, '"$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "two uploads" 2 "$(requests upload)"
expect "first wait is 5 s ± 20%" test "$(<"$FAKE_SLEEP_LOG")" -ge 4 -a "$(<"$FAKE_SLEEP_LOG")" -le 6

begin "no answer: retried"
on_push "$c2"
start_app '[{"drop": true}, '"$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "two uploads" 2 "$(requests upload)"

begin "5xx every time: five attempts, then failure"
on_push "$c2"
start_app '[{"status": 500, "body": {"error": "internal"}}, {"status": 502, "body": {}}, {"status": 503, "body": {"error": "unavailable"}}, {"status": 504, "body": {}}, {"status": 503, "body": {"error": "unavailable"}}]'
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "five uploads" 5 "$(requests upload)"
expect_eq "app-status" 503 "$(out app-status)"
expect "the error says the App is unavailable" log_has "The App is unavailable"

begin "400 envelope_invalid: final, with a hint"
on_push "$c2"
start_app '[{"status": 400, "body": {"error": "envelope_invalid"}}]'
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "one upload" 1 "$(requests upload)"
expect "the error names the App's code" log_has "HTTP 400 envelope_invalid"
expect "the error gives the recovery" log_has "action commit the App pins"
expect_eq "app-answer" '{"error":"envelope_invalid"}' "$(out app-answer)"

begin "404: final, endpoint hint"
on_push "$c2"
start_app '[{"status": 404, "body": {}}]'
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "one upload" 1 "$(requests upload)"
expect "the error explains the endpoint" log_has "endpoint must be the App base URL"

begin "400 method_not_allowed: final, proxy hint"
on_push "$c2"
start_app '[{"status": 400, "body": {"error": "method_not_allowed"}}]'
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "one upload" 1 "$(requests upload)"
expect "the error names the proxy" log_has "A proxy changed the request method"

begin "409 stale_head: superseded, not a failure"
on_push "$c2"
start_app '[{"status": 409, "body": {"error": "stale_head"}}]'
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "one upload" 1 "$(requests upload)"
expect "the notice says the upload was superseded" log_has "supersedes this upload"
expect_eq "app-status" 409 "$(out app-status)"

begin "explicit audience"
on_push "$c2"
start_app "[$ok_answer]"
export ARCHFIT_AUDIENCE=https://archfit.example
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "the token audience is the input, URL-encoded" \
	"api-version=2.0&audience=https%3A%2F%2Farchfit.example" "$(token_query)"

begin "payload over the App's 5 MiB cap: refused before sending"
on_push "$c2"
start_app "[$ok_answer]"
export FAKE_STATE=$case_dir/huge.json
{
	cat "$state_doc"
	head -c 5300000 /dev/zero | tr '\0' ' '
} >"$FAKE_STATE"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect "the error names the cap" log_has "accepts at most 5242880"

# --- Edge cases -----------------------------------------------------------------------

begin "fork pull request: analysed, nothing sent"
on_pull_request "$f1" "$c1" someone/shop
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect_eq "no token requested" 0 "$(requests token)"
expect "the notice explains forks" log_has "fork pull request"
expect "the envelope is still written and valid" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect_eq "the report is still produced" archfit-report "$(out artifact-name)"

begin "no policy on the protected ref: nothing measured, nothing sent"
on_push "$np"
start_app "[$ok_answer]"
run_action "$no_policy"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "no engine run" 0 "$(engine_calls)"
expect_eq "no upload" 0 "$(requests upload)"
expect "the notice names discovery" log_has "discover: true"
expect_eq "no payload" "" "$(out payload-file)"

begin "engine exit 3: failure with the engine's reason, nothing sent"
on_push "$c2"
start_app "[$ok_answer]"
export FAKE_CHECK_RC=3
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect "the error says no report was produced" log_has "no report was produced"
expect "the error carries the engine's stderr" log_has "go list exited 1"

begin "foreign schema_version: refused, nothing sent"
on_push "$c2"
start_app "[$ok_answer]"
printf '{"schema_version":"something.else.v9","verdict":"healthy"}\n' >"$case_dir/foreign.json"
export FAKE_STATE=$case_dir/foreign.json FAKE_CHECK_RC=0
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect "the error names the schema" log_has "something.else.v9"

begin "endpoint without id-token permission"
on_push "$c2"
start_app "[$ok_answer]"
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect "the error names the permission" log_has "id-token: write"

begin "no endpoint: analysis only; a blocked verdict fails the job"
on_push "$c2"
run_action "$origin"
expect_eq "the action fails on blocked" 1 "$action_rc"
expect "the envelope is written and valid" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect "the error says why" log_has "verdict is blocked"

begin "no endpoint: needs_attention passes"
on_push "$c2"
jq '.verdict = "needs_attention"' "$state_doc" >"$case_dir/attention.json"
export FAKE_STATE=$case_dir/attention.json
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "verdict" needs_attention "$(out verdict)"

begin "an image tag is refused before any work"
on_push "$c2"
export ARCHFIT_IMAGE_DIGEST=v2.3.1
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error refuses tags" log_has "tags are refused"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

begin "an image of another engine version is refused before analysis"
on_push "$c2"
export FAKE_ENGINE_VERSION=v2.4.0
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names both versions" log_has "is engine v2.4.0, not v2.3.1"
expect_eq "only the version probe ran" 1 "$(engine_calls)"

begin "an image for another platform than the runner is refused before any container"
on_push "$c2"
export FAKE_PLATFORM=linux/arm64
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names both platforms" log_has "built for linux/arm64, but this runner is linux/amd64"
expect_eq "no container ran" 0 "$(engine_calls)"

begin "an ARM64 runner takes the arm64 image"
on_push "$c2"
export FAKE_PLATFORM=linux/arm64 RUNNER_ARCH=ARM64
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "platform" linux/arm64 "$(envelope_field platform)"

begin "a runner architecture without an engine image is refused"
on_push "$c2"
export RUNNER_ARCH=X86
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the architecture" log_has "runner architecture 'X86'"
expect_eq "no container ran" 0 "$(engine_calls)"

begin "a dispatched report is refused before any work"
on_dispatch "$c2" false
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the recovery" log_has "dispatch with discover: true"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

begin "a dispatched baseline is allowed"
on_dispatch "$c2" false
export ARCHFIT_MODE=baseline
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "artifact name" archfit-baseline "$(out artifact-name)"

begin "discover: true conflicts with mode: baseline"
on_dispatch "$c2" true
export ARCHFIT_MODE=baseline
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the conflict" log_has "conflicts with discover: true"

begin "discovery off the default branch is refused before any work"
on_pull_request "$f1" "$c1"
export ARCHFIT_DISCOVER=true
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the default branch" log_has "default branch (main) only"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

begin "credentials persisted in .git/config never reach the engine container"
on_push "$c2"
action_rc=0
{
	bash "$root/scripts/prepare.sh"
	checkout "$origin" "$(out ref)"
	git -C "$GITHUB_WORKSPACE" config --local http.https://github.com/.extraheader "AUTHORIZATION: basic c2VjcmV0"
	ARCHFIT_MODE=$(out mode) bash "$root/scripts/run.sh"
} >"$case_dir/log" 2>&1 || action_rc=$?
expect_eq "the action fails" 1 "$action_rc"
expect "the error explains the credential" log_has "keeps credentials in .git/config"
expect_eq "no docker call" 0 "$(jq -s length "$FAKE_DOCKER_LOG")"

# --- Baseline capture -----------------------------------------------------------------

begin "baseline: captured in the image, self-checked, kept as an artifact"
on_push "$c2"
export ARCHFIT_MODE=baseline
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "capture runs with the protected policy and labels, never a stored baseline" json_ok \
	'.args == ["baseline", "-c", "/bundle/.archfit.yaml", "--root", "/src"]
	 and (.bundle | keys) == [".archfit-labels.yaml", ".archfit.yaml"]' "$(engine_call baseline)"
expect "the self-check reads the captured baseline" json_ok '.bundle | has(".archfit-baseline.json")' "$(engine_call check)"
expect_eq "the payload is the captured file" .archfit-baseline.json "$(basename "$(out payload-file)")"
expect_eq "artifact name" archfit-baseline "$(out artifact-name)"
expect_eq "no envelope: the App has no baseline upload yet" "" "$(out envelope-file)"
expect_eq "nothing sent" 0 "$(requests upload)"

begin "baseline that this image finds non-comparable: failure"
on_push "$c2"
export ARCHFIT_MODE=baseline FAKE_BASELINE_COMPARABLE=false
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error says why" log_has "not comparable in this image"

finish
