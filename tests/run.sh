#!/usr/bin/env bash
# Conformance and behaviour tests for the action's scripts.
#
# The shipped scripts run unchanged, in action.yml order (prepare, checkout, run,
# report), against scratch git repositories and recorded event payloads. Only the
# process and network boundaries are faked: a docker shim stands in for the engine
# image and replays results the engine emitted (tests/fixtures/result), a local server
# plays the App and the OIDC token service, and a no-op sleep replaces the backoff
# clock. Every envelope the scripts write is validated against the vendored App
# schema, and known-bad envelopes must fail the same validator.
#
# Needs bash, git, jq, curl, python3 and go.
# shellcheck disable=SC2016 # single-quoted $names are jq's
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

results=$root/tests/fixtures/result
tmp=$(mktemp -d "${TMPDIR:-/tmp}/archfit-action-tests.XXXXXX")
app_pid=""
stop_app() {
	[[ -n $app_pid ]] || return 0
	kill "$app_pid" 2>/dev/null || true
	wait "$app_pid" 2>/dev/null || true
	app_pid=""
}
trap 'stop_app; rm -rf "$tmp"' EXIT

schema=$root/schema/envelope.v2.schema.json
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

git_as_test() { git -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }
# replace FILE FROM TO: one textual edit, the same with GNU and BSD tools.
replace() {
	local text
	text=$(<"$1")
	printf '%s\n' "${text/"$2"/"$3"}" >"$1"
}

# Fixture: main (c1) holds code and policy; feature (f1) branches from c1 and changes code
# only; main then moves on (c2) and changes only the policy's owners. edit (e1) branches
# from c1 and edits the policy; drop (d1) deletes it. YAML checks out with CRLF line ends,
# so working-tree bytes differ from blob bytes.
origin=$tmp/origin
git init --quiet -b main "$origin"
write_module "$origin"
printf '*.yaml text eol=crlf\n' >"$origin/.gitattributes"
commit_all "$origin" "code and policy"
c1=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet -b feature
printf '\n// Twice calls b twice.\nfunc Twice() string { return UseB() + UseB() }\n' >>"$origin/pkg/a/a.go"
commit_all "$origin" "feature: code only"
f1=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet main
replace "$origin/.archfit.yaml" "owners: [acme-owner]" "owners: [acme-owner, acme-second]"
commit_all "$origin" "main: a second owner"
c2=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet -b edit "$c1"
printf '# loosened by the change\n' >>"$origin/.archfit.yaml"
commit_all "$origin" "edit: the policy"
e1=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet -b drop "$c1"
git -C "$origin" rm --quiet .archfit.yaml
commit_all "$origin" "drop: delete the policy"
d1=$(git -C "$origin" rev-parse HEAD)
# Merge groups for the queue of main, built on c2 as GitHub builds them: gc holds f1 (code
# only); ge holds e1, so it edits the policy.
group() { # BRANCH PULL-REQUEST-HEAD: a group commit merging the head onto c2
	git -C "$origin" checkout --quiet -b "$1" "$c2"
	git_as_test -C "$origin" merge --quiet --no-ff -m "group $1" "$2" >/dev/null
	git -C "$origin" rev-parse HEAD
}
gc=$(group queue-code "$f1")
ge=$(group queue-edit "$e1")
git -C "$origin" checkout --quiet main

# Criss-cross: x2 and y2 each merge the other's first commit, so they have two merge bases.
cross=$tmp/cross
git init --quiet -b main "$cross"
write_module "$cross"
commit_all "$cross" "code and policy"
merge() { git_as_test -C "$cross" merge --quiet --no-ff --no-edit "$1"; }
git -C "$cross" checkout --quiet -b x
printf '// x\n' >>"$cross/pkg/a/a.go"
commit_all "$cross" "x1"
git -C "$cross" checkout --quiet -b y main
printf '// y\n' >>"$cross/pkg/b/b.go"
commit_all "$cross" "y1"
y1=$(git -C "$cross" rev-parse HEAD)
git -C "$cross" checkout --quiet x
merge "$y1"
x2=$(git -C "$cross" rev-parse HEAD)
git -C "$cross" checkout --quiet y
merge "$(git -C "$cross" rev-parse x~1)"
git -C "$cross" checkout --quiet main

# no_policy: code without a policy (np); its branch first (p1) proposes the first one.
no_policy=$tmp/no-policy
git init --quiet -b main "$no_policy"
write_module "$no_policy"
mv "$no_policy/.archfit.yaml" "$tmp/first-policy.yaml"
commit_all "$no_policy" "code without a policy"
np=$(git -C "$no_policy" rev-parse HEAD)
git -C "$no_policy" checkout --quiet -b first
cp "$tmp/first-policy.yaml" "$no_policy/.archfit.yaml"
commit_all "$no_policy" "first: the first policy"
p1=$(git -C "$no_policy" rev-parse HEAD)
git -C "$no_policy" checkout --quiet main

# From here a failing check is recorded, not fatal.
set +e

begin() { # NAME
	stop_app
	new_case "$1"
	export FAKE_DOCKER_LOG=$case_dir/docker.log FAKE_SLEEP_LOG=$case_dir/sleep.log FAKE_RESULT=$results/pass.json
	unset FAKE_CHECK_RC FAKE_ENGINE_VERSION FAKE_PLATFORM
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
check_calls() { jq -cs 'map(select(.command == "run" and .args[0] == "check"))' "$FAKE_DOCKER_LOG"; }
engine_calls() { jq -s 'map(select(.command == "run")) | length' "$FAKE_DOCKER_LOG"; }
engine_call() { jq -cs --arg a "$1" 'map(select(.command == "run" and .args[0] == $a))[0]' "$FAKE_DOCKER_LOG"; }
json_ok() { jq -e "$1" "${@:3}" <<<"$2" >/dev/null; } # FILTER JSON [JQ ARGS]
valid_envelope() { "$validator" "$schema" "$1=$2" >"$case_dir/validator.out" 2>&1; }
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
ok_answer='{"status": 200, "body": {"status": "pass"}}'
summary_has() { grep -qF -- "$1" "$GITHUB_STEP_SUMMARY"; }
# check_args JSON-ARRAY: the engine arguments of the case's one check call equal it.
check_args() { json_ok '.args == $want' "$(engine_call check)" --argjson want "$1"; }
target_args='["check", "--format", "json", "--base", "refs/remotes/origin/main", "--policy", "/archfit/policy/.archfit.yaml"]'
checkout_args='["check", "--format", "json", "--base", "refs/remotes/origin/main"]'

# --- Contract provenance -----------------------------------------------------------

begin "vendored schema and fixtures match their sources"
expect_eq "schema/envelope.v2.schema.json sha256" \
	"$(sed -n 's/^sha256: //p' "$root/schema/SCHEMA_SOURCE")" "$(sha_of "$schema")"
expect_eq "SCHEMA_SOURCE names the vendored path" internal/wire/envelope/envelope.v2.schema.json \
	"$(sed -n 's/^path: //p' "$root/schema/SCHEMA_SOURCE")"
for fixture in "$results"/*.json; do
	name=result/$(basename "$fixture")
	expect_eq "$name matches tests/fixtures/SOURCE.md" \
		"$(sed -n "s/^| \`${name//\//\\/}\` | \`\([0-9a-f]\{64\}\)\` |\$/\1/p" "$root/tests/fixtures/SOURCE.md")" "$(sha_of "$fixture")"
done

# --- One check per trigger ------------------------------------------------------------

begin "pull request: the head is checked, the policy is the target tip's blob, envelope 2 and upload"
on_pull_request "$f1" "$c2"
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
envelope=$(out envelope-file) payload=$(out payload-file)
expect "the envelope conforms to the App schema" valid_envelope "$envelope" "$payload"
cp "$envelope" "$tmp/pull_request.envelope"
cp "$payload" "$tmp/pull_request.result"
expect_eq "schema_version" archfit.upload-envelope.v2 "$(envelope_field schema_version)"
expect_eq "event and pull request number" "pull_request 42" "$(envelope_field event) $(envelope_field pull_request)"
expect_eq "head_sha is the pull request head, not GITHUB_SHA" "$f1" "$(envelope_field head_sha)"
expect_eq "the checkout is the head" "$f1" "$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)"
expect_eq "merge_base_sha is merge-base(head, target tip)" "$c1" "$(envelope_field merge_base_sha)"
expect_eq "target_ref" refs/heads/main "$(envelope_field target_ref)"
expect_eq "target_sha is the target tip fetched in this run, not the event's base" "$c2" "$(envelope_field target_sha)"
expect_eq "policy_digest is the digest the result names" \
	"$(jq -r .policy.digest "$payload")" "$(envelope_field policy_digest)"
expect_eq "run_id and run_attempt are integers" "number number" \
	"$(jq -r '[.run_id, .run_attempt] | map(type) | join(" ")' "$envelope")"
expect_eq "engine identity" "$ENGINE_VERSION $ENGINE_DIGEST linux/amd64" \
	"$(envelope_field engine_version) $(envelope_field image_digest) $(envelope_field platform)"
expect "no v1 key is left" json_ok '[keys[] | select(IN("kind", "base_sha", "analyzed_sha", "integration",
	"baseline_digest", "labels_digest", "policy_change"))] == []' "$(<"$envelope")"
expect "engine arguments: one check against the full target ref, with the target's policy" check_args "$target_args"
expect_eq "one engine check" 1 "$(check_calls | jq length)"
expect_eq "the engine judges with the target tip's policy blob" \
	"$(blob_sha256 "$origin" "$c2:.archfit.yaml")" "$(engine_call check | jq -r .policy)"
options=$(engine_call check | jq -c .options)
expect "container runs as the workspace owner" \
	json_ok 'index("--user") as $i | .[$i + 1] == $u' "$options" --arg u "$(id -u):$(id -g)"
expect "container gets only fixed HOME and checkout-scoped Git trust" \
	json_ok '[range(length) as $i | select(.[$i] == "--env" or .[$i] == "-e") | .[$i + 1]] ==
	  ["HOME=/tmp", "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=safe.directory", "GIT_CONFIG_VALUE_0=/src"]' "$options"
expect "no env file" json_ok 'index("--env-file") == null' "$options"
expect "no token or OIDC variable reaches the container" \
	json_ok '[.options[], .args[]] | map(select(test("ACTIONS_|TOKEN"))) == []' "$(engine_call check)"
expect "the mounts: the checkout, .git read-only, the policy copy read-only; nothing else" json_ok \
	'[range(length) as $i | select(.[$i] == "--volume") | .[$i + 1]] ==
	  [$s + ":/src", $s + "/.git:/src/.git:ro", $p + ":/archfit/policy/.archfit.yaml:ro"]' \
	"$options" --arg s "$GITHUB_WORKSPACE" --arg p "$RUNNER_TEMP/archfit/policy/.archfit.yaml"
expect "the image is pinned by digest and never pulled implicitly" \
	json_ok '.image == $i and (.options | index("never")) != null' "$(engine_call check)" \
	--arg i "ghcr.io/alexei-led/archfit@$ENGINE_DIGEST"
expect_eq "one upload" 1 "$(requests upload)"
expect_eq "route" /v1/reports "$(upload_field 0 .path)"
expect_eq "the header carries the envelope file byte for byte" "$(<"$envelope")" "$(upload_field 0 .envelope)"
expect_eq "the body is the engine's result, byte for byte" "$(sha_of "$results/pass.json")" "$(upload_field 0 .body_sha256)"
expect_eq "the payload digest names the body" "$(envelope_field payload_digest)" "sha256:$(upload_field 0 .body_sha256)"
expect_eq "content type" application/json "$(upload_field 0 .content_type)"
expect_eq "authorization is the minted OIDC token" "Bearer oidc-1" "$(upload_field 0 .authorization)"
expect_eq "the token audience is the endpoint, URL-encoded" \
	"api-version=2.0&audience=$(jq -rn --arg a "$ARCHFIT_ENDPOINT" '$a | @uri')" "$(token_query)"
expect_eq "app-status" 200 "$(out app-status)"
expect_eq "app-answer" '{"status":"pass"}' "$(out app-answer)"
expect_eq "verdict is the result's status" pass "$(out verdict)"
expect_eq "artifact name the App reads the result from" archfit-result "$(out artifact-name)"
expect "the step summary names the head" summary_has "head \`$f1\` of pull request #42"
expect "the step summary names the target tip" summary_has "\`refs/heads/main\` at \`$c2\`"
expect "the step summary names the policy's source" summary_has "of the target tip, \`sha256:$(blob_sha256 "$origin" "$c2:.archfit.yaml")\`"

begin "push at the target tip: the engine reads the checkout's policy and adds the repository state"
on_push "$c2"
export FAKE_RESULT=$results/push-at-tip.json
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"
cp "$(out envelope-file)" "$tmp/push.envelope"
expect_eq "pull_request is 0 off pull requests" 0 "$(envelope_field pull_request)"
expect_eq "head, merge base and target tip are the pushed commit" "$c2 $c2 $c2" \
	"$(envelope_field head_sha) $(envelope_field merge_base_sha) $(envelope_field target_sha)"
expect "no --policy: the tip's tree holds the tip's policy" check_args "$checkout_args"
expect "no policy copy is mounted" json_ok '[.options[] | select(contains("/archfit/policy"))] == []' "$(engine_call check)"
expect_eq "the body is the engine's result untouched, repository state included" \
	"$(sha_of "$results/push-at-tip.json")" "$(upload_field 0 .body_sha256)"
expect "the result carries the repository state (fixture sanity)" jq -e '.repository.state == "clean"' "$(out payload-file)"
expect "the step summary says the checkout is the tip" summary_has "of the checkout, which is the target tip"

begin "push at the tip of a repository whose .gitattributes converts the policy: unknown"
# The engine compares the checkout's CRLF file with the tip's LF blob (engine-emitted).
on_push "$c2"
export FAKE_RESULT=$results/eol-differs.json
run_action "$origin"
expect "no --policy at the tip, so the engine reads the converted working-tree file" check_args "$checkout_args"
expect_eq "the job fails: without an App this job is the gate" 1 "$action_rc"
expect_eq "verdict" unknown "$(out verdict)"
expect "the error says there is no verdict" log_has "has no verdict (status unknown)"
expect "the result names the difference" jq -e '.policy.differs and (.unknown[0].what | startswith("differs from"))' "$(out payload-file)"

begin "push behind the target tip: the tip's policy judges the pushed commit"
on_push "$c1"
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "head and merge base are the pushed commit, the target is the tip" "$c1 $c1 $c2" \
	"$(envelope_field head_sha) $(envelope_field merge_base_sha) $(envelope_field target_sha)"
expect "the tip's policy is passed" check_args "$target_args"
expect_eq "it is the tip's blob" "$(blob_sha256 "$origin" "$c2:.archfit.yaml")" "$(engine_call check | jq -r .policy)"

begin "merge group: the group commit, judged by the default branch's policy"
on_merge_group "$gc" "$c2"
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"
cp "$(out envelope-file)" "$tmp/merge_group.envelope"
expect_eq "the checkout is the group commit" "$gc" "$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)"
expect_eq "event, pull request, head" "merge_group 0 $gc" \
	"$(envelope_field event) $(envelope_field pull_request) $(envelope_field head_sha)"
expect_eq "target and merge base are the queue's base, the default branch tip" "refs/heads/main $c2 $c2" \
	"$(envelope_field target_ref) $(envelope_field target_sha) $(envelope_field merge_base_sha)"
expect "the default branch's policy is passed" check_args "$target_args"
# The group commit holds the tip's policy unchanged, checked out with CRLF line ends.
expect "the checkout's policy is the CRLF working-tree file (fixture sanity)" grep -q $'\r' "$GITHUB_WORKSPACE/.archfit.yaml"
expect "the judged bytes are the tip's blob, not the working tree's" \
	test "$(sha_of "$GITHUB_WORKSPACE/.archfit.yaml")" != "$(engine_call check | jq -r .policy)"
expect_eq "they are the tip's blob" "$(blob_sha256 "$origin" "$c2:.archfit.yaml")" "$(engine_call check | jq -r .policy)"
expect "the summary names the group commit" summary_has "merge group commit \`$gc\` on base \`$c2\`"

begin "merge group that edits the policy: the engine compares it with the default branch's"
on_merge_group "$ge" "$c2"
export FAKE_RESULT=$results/policy-differs.json
start_app '[{"status": 200, "body": {"status": "unknown", "reason": "policy_not_target"}}]'
run_action "$origin"
expect_eq "the action succeeds: the App's check carries the status" 0 "$action_rc"
expect "no --policy" check_args "$checkout_args"
expect_eq "the unknown result is uploaded" 1 "$(requests upload)"
expect "the envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"

# --- A change that edits the policy: unknown, never judged by its own policy -----------

begin "pull request that edits the policy: no --policy, the engine's unknown is uploaded"
on_pull_request "$e1" "$c2"
export FAKE_RESULT=$results/policy-differs.json
start_app '[{"status": 200, "body": {"status": "unknown", "reason": "policy_not_target"}}]'
run_action "$origin"
expect_eq "the action succeeds: the App's check carries the status" 0 "$action_rc"
expect "the engine compares the checkout's policy with the target's" check_args "$checkout_args"
expect "no policy copy is mounted" json_ok '[.options[] | select(contains("/archfit/policy"))] == []' "$(engine_call check)"
expect_eq "verdict" unknown "$(out verdict)"
expect "the envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect_eq "policy_digest is the digest the result names" \
	"$(jq -r .policy.digest "$(out payload-file)")" "$(envelope_field policy_digest)"
expect "the log shows the App's answer" log_has "status unknown, reason policy_not_target"
expect "the step summary says the change edits the policy" summary_has "the change edits it, so the engine compares it with the target's"

begin "pull request that edits the policy, without an App: the job fails"
on_pull_request "$e1" "$c2"
export FAKE_RESULT=$results/policy-differs.json
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error says there is no verdict" log_has "has no verdict (status unknown)"
expect "the envelope is still written and valid" valid_envelope "$(out envelope-file)" "$(out payload-file)"

begin "pull request that deletes the policy: the engine runs and compares"
on_pull_request "$d1" "$c2"
export FAKE_RESULT=$results/policy-differs.json
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "no --policy" check_args "$checkout_args"
expect_eq "the result is uploaded" 1 "$(requests upload)"

# --- A re-run reads the target tip as it is then (design 10.5) -----------------------

begin "re-run after a policy-only commit on the target: the new tip's policy judges the same head"
rerun_origin=$case_dir/rerun-origin
git clone --quiet --bare "$origin" "$rerun_origin"
on_pull_request "$f1" "$c2"
start_app "[$ok_answer, $ok_answer]"
run_action "$rerun_origin"
expect_eq "the first attempt succeeds" 0 "$action_rc"
expect_eq "the first attempt reads c2" "$c2" "$(envelope_field target_sha)"
# An owner's answer lands on main: a policy-only commit, after the event was sent.
work_clone=$case_dir/answer
git clone --quiet "$rerun_origin" "$work_clone"
replace "$work_clone/.archfit.yaml" "volatility: high" "volatility: medium"
commit_all "$work_clone" "main: the owner's answer"
git -C "$work_clone" push --quiet origin main
c3=$(git -C "$work_clone" rev-parse HEAD)
# GitHub re-runs replay the original event payload; the job checks out and fetches anew.
rm -rf "$GITHUB_WORKSPACE" "$RUNNER_TEMP"
mkdir -p "$RUNNER_TEMP"
: >"$GITHUB_OUTPUT"
: >"$FAKE_DOCKER_LOG"
export GITHUB_RUN_ATTEMPT=2
run_action "$rerun_origin"
expect_eq "the re-run succeeds" 0 "$action_rc"
expect "the re-run's envelope conforms to the App schema" valid_envelope "$(out envelope-file)" "$(out payload-file)"
cp "$(out envelope-file)" "$tmp/rerun.envelope"
expect_eq "run_attempt" 2 "$(envelope_field run_attempt)"
expect_eq "head_sha is unchanged" "$f1" "$(envelope_field head_sha)"
expect_eq "target_sha is the new tip, not the event's base" "$c3" "$(envelope_field target_sha)"
expect_eq "the engine judges with the new tip's policy" \
	"$(blob_sha256 "$rerun_origin" "$c3:.archfit.yaml")" "$(engine_call check | jq -r .policy)"
expect "the new tip's policy differs from the old (fixture sanity)" \
	test "$(blob_sha256 "$rerun_origin" "$c3:.archfit.yaml")" != "$(blob_sha256 "$rerun_origin" "$c2:.archfit.yaml")"
expect_eq "two uploads" 2 "$(requests upload)"

# --- The target ref is unambiguous ----------------------------------------------------

begin "a tag named origin/main does not change the target"
tagged=$case_dir/tagged
git clone --quiet --bare "$origin" "$tagged"
git -C "$tagged" tag origin/main "$e1"
on_pull_request "$f1" "$c2"
start_app "[$ok_answer]"
run_action "$tagged"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the tag reached the checkout (fixture sanity)" \
	test "$(git -C "$GITHUB_WORKSPACE" rev-parse origin/main 2>/dev/null)" == "$e1"
expect_eq "target_sha is the branch tip" "$c2" "$(envelope_field target_sha)"
expect "the engine gets the full remote-tracking ref" check_args "$target_args"
expect_eq "the policy is the branch tip's" "$(blob_sha256 "$origin" "$c2:.archfit.yaml")" "$(engine_call check | jq -r .policy)"

begin "pull request into a branch that was not fetched: refused"
on_pull_request "$f1" "$c2"
jq '.pull_request.base.ref = "release"' "$GITHUB_EVENT_PATH" >"$case_dir/release.json"
export GITHUB_EVENT_PATH=$case_dir/release.json
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the branch" log_has "the target branch release was not fetched"
expect_eq "no engine run" 0 "$(engine_calls)"

begin "criss-cross pull request with two merge bases: refused"
on_pull_request "$x2" "$(git -C "$cross" rev-parse y)"
jq '.pull_request.base.ref = "y"' "$GITHUB_EVENT_PATH" >"$case_dir/cross.json"
export GITHUB_EVENT_PATH=$case_dir/cross.json
run_action "$cross"
expect_eq "the action fails" 1 "$action_rc"
expect "the error explains the merge bases" log_has "more than one merge base"
expect_eq "no engine run" 0 "$(engine_calls)"

# --- No policy to check with ----------------------------------------------------------

begin "no policy on the target and none in the change: nothing checked, nothing sent"
on_push "$np"
start_app "[$ok_answer]"
run_action "$no_policy"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "no engine run" 0 "$(engine_calls)"
expect_eq "no upload" 0 "$(requests upload)"
expect "the notice names archfit init" log_has "Run archfit init"
expect_eq "no payload" "" "$(out payload-file)"

begin "the first policy in a pull request: checked with it, the App decides"
on_pull_request "$p1" "$np"
start_app "[$ok_answer]"
run_action "$no_policy"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the engine reads the checkout's policy" check_args "$checkout_args"
expect_eq "the result is uploaded" 1 "$(requests upload)"

# --- Events the App does not accept: refused before the checkout ----------------------

for refused in workflow_run pull_request_target workflow_dispatch; do
	begin "$refused is refused before the checkout"
	on_unsupported "$refused" "$f1" "$c2"
	start_app "[$ok_answer]"
	run_action "$origin"
	expect_eq "the action fails" 1 "$action_rc"
	expect "the error names the event" log_has "'$refused' is refused before the checkout"
	expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"
	expect_eq "no engine run" 0 "$(engine_calls)"
	expect_eq "no token requested" 0 "$(requests token)"
done

begin "a tag push is refused before the checkout"
on_push "$c2" refs/tags/v1.0.0
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error says a tag has no target branch" log_has "not a branch; archfit checks pushes to branches only"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

for removed in discovery baseline reanchor; do
	begin "mode $removed is refused before the checkout"
	on_push "$c2"
	export ARCHFIT_MODE=$removed
	run_action "$origin"
	expect_eq "the action fails" 1 "$action_rc"
	expect "the error says Action 4 only checks" log_has "mode '$removed' is not supported"
	expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"
done

# --- Merge groups: the group commit the event names, tied to the queue's base ----------

for mismatch in sha ref; do
	begin "merge group whose job context is not the event's group ($mismatch): refused before the checkout"
	on_merge_group "$gc" "$c2"
	case $mismatch in
	sha) export GITHUB_SHA=$ge ;;
	ref) export GITHUB_REF=refs/heads/gh-readonly-queue/main/pr-7-$ge ;;
	esac
	start_app "[$ok_answer]"
	run_action "$origin"
	expect_eq "the action fails" 1 "$action_rc"
	expect "the error names the event's group" log_has "but the merge_group event names"
	expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"
	expect_eq "no token requested" 0 "$(requests token)"
done

begin "merge group action other than checks_requested: refused"
on_merge_group "$gc" "$c2" destroyed
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the action" log_has "merge_group action 'destroyed' is not checks_requested"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

begin "merge group for another branch's queue: refused"
on_merge_group "$gc" "$c2" checks_requested refs/heads/release
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the default branch" log_has "merge queue of the default branch (main) only"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

begin "merge group not built on the event's base: refused before the engine"
on_merge_group "$gc" "$e1"
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the base" log_has "is not built on the event's base $e1"
expect_eq "no engine run" 0 "$(engine_calls)"
expect_eq "no token requested" 0 "$(requests token)"

begin "merge group whose base is not in the default branch's history: refused"
on_merge_group "$ge" "$e1"
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the branch" log_has "base $e1 is not in the history of main"
expect_eq "no engine run" 0 "$(engine_calls)"

begin "merge group whose base is not fetched: refused"
on_merge_group "$gc" 0123456789abcdef0123456789abcdef01234567
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the commit" log_has "base commit 0123456789abcdef0123456789abcdef01234567 is not in the fetched history"

begin "merge group the App no longer queues (409 stale_group): final, no retry"
on_merge_group "$gc" "$c2"
start_app '[{"status":409,"body":{"error":"stale_group"}}]'
run_action "$origin"
expect_eq "the action succeeds: the App owns the group's check" 0 "$action_rc"
expect_eq "one upload, no retry" 1 "$(requests upload)"
expect "the notice names the code" log_has "the App answered 409 stale_group"

# --- Without an App: the job is the gate -----------------------------------------------

begin "no endpoint, pass: the job passes, nothing is sent"
on_pull_request "$f1" "$c2"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the envelope is written and valid" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect "the notice says nothing was sent" log_has "no endpoint: nothing was sent"

begin "no endpoint, fail: the job fails"
on_pull_request "$f1" "$c2"
export FAKE_RESULT=$results/fail.json
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "verdict" fail "$(out verdict)"
expect "the error points at the artifact" log_has "the archfit-result artifact lists the errors"

# --- The result: one engine pass, its exit code and status agree ------------------------

begin "fail with an endpoint: uploaded, the job passes"
on_pull_request "$f1" "$c2"
export FAKE_RESULT=$results/fail.json
start_app '[{"status": 200, "body": {"status": "fail"}}]'
run_action "$origin"
expect_eq "the action succeeds: the App's check carries the status" 0 "$action_rc"
expect_eq "verdict" fail "$(out verdict)"
expect "the step summary gives the App's status" summary_has "accepted the result (200): status fail"

begin "exit code and status disagree: refused, nothing sent"
on_pull_request "$f1" "$c2"
export FAKE_RESULT=$results/fail.json FAKE_CHECK_RC=0
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names both" log_has "archfit exited 0, but its result says fail"
expect_eq "no upload" 0 "$(requests upload)"

begin "status waiting is the App's, never the engine's: refused"
on_pull_request "$f1" "$c2"
# Deliberately contradictory negative input, not an engine capture.
jq '.status = "waiting"' "$results/fail.json" >"$case_dir/waiting.json"
export FAKE_RESULT=$case_dir/waiting.json FAKE_CHECK_RC=1
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the status" log_has "no status the engine gives ('waiting')"
expect_eq "no upload" 0 "$(requests upload)"

begin "exit 2 without a result: a tool error, the engine's reason in the log"
on_pull_request "$f1" "$c2"
export FAKE_RESULT=none
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error says no result was produced" log_has "archfit exited 2 without a result"
expect "the error carries the engine's stderr" log_has "git add --all exited 128"
expect_eq "no upload" 0 "$(requests upload)"

begin "the container fails (exit 125): failure, nothing sent"
on_pull_request "$f1" "$c2"
export FAKE_CHECK_RC=125
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the exit" log_has "the engine container exited 125"
expect_eq "no upload" 0 "$(requests upload)"

begin "foreign schema: refused, nothing sent"
on_pull_request "$f1" "$c2"
printf '{"schema":"archfit.architecture-state.v1","status":"pass"}\n' >"$case_dir/foreign.json"
export FAKE_RESULT=$case_dir/foreign.json FAKE_CHECK_RC=0
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the schema" log_has "declares schema 'archfit.architecture-state.v1'"
expect_eq "no upload" 0 "$(requests upload)"

begin "a result without a policy digest: refused"
on_pull_request "$f1" "$c2"
jq 'del(.policy.digest)' "$results/pass.json" >"$case_dir/no-digest.json"
export FAKE_RESULT=$case_dir/no-digest.json
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the digest" log_has "the result names no policy digest"
expect_eq "no upload" 0 "$(requests upload)"

begin "fork pull request: checked, nothing sent"
on_pull_request "$f1" "$c2" someone/shop
start_app "[$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect_eq "no token requested" 0 "$(requests token)"
expect "the notice explains forks" log_has "fork pull request"
expect "the envelope is still written and valid" valid_envelope "$(out envelope-file)" "$(out payload-file)"
expect_eq "the result is still kept" archfit-result "$(out artifact-name)"

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

begin "Retry-After with a leading zero is decimal"
on_push "$c2"
start_app '[{"status": 503, "headers": {"Retry-After": "08"}, "body": {}}, '"$ok_answer]"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "waits 8 s" 8 "$(<"$FAKE_SLEEP_LOG")"

for after in "Wed, 21 Oct 2015 07:28:00 GMT" 99999 -5 9x; do
	begin "Retry-After '$after' falls back to backoff"
	on_push "$c2"
	start_app "[{\"status\": 503, \"headers\": {\"Retry-After\": \"$after\"}, \"body\": {}}, $ok_answer]"
	run_action "$origin"
	expect_eq "the action succeeds" 0 "$action_rc"
	expect_eq "two uploads" 2 "$(requests upload)"
	expect "the wait is the 5 s backoff" test "$(<"$FAKE_SLEEP_LOG")" -ge 4 -a "$(<"$FAKE_SLEEP_LOG")" -le 6
done

begin "App strings are never echoed raw: no workflow command, no markdown"
on_push "$c2"
start_app '[{"status": 200, "body": {"status": "pass\n::error::injected", "reason": "[click](https://evil.example)"}}]'
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "no injected workflow command in the log" bash -c '! grep -q "^::error::injected" "$1"' _ "$case_dir/log"
expect "no injected link in the step summary" bash -c '! grep -q "evil.example" "$1"' _ "$GITHUB_STEP_SUMMARY"
expect "the log says the values were unexpected" log_has "status (unexpected value), reason (unexpected value)"

begin "an unexpected error code is not echoed"
on_push "$c2"
start_app '[{"status": 400, "body": {"error": "x\n::error::injected"}}]'
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "no injected workflow command in the log" bash -c '! grep -q "^::error::injected" "$1"' _ "$case_dir/log"

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

begin "403 workflow_path: final, the hint names the fixed workflow"
on_push "$c2"
start_app '[{"status": 403, "body": {"error": "workflow_path"}}]'
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "one upload" 1 "$(requests upload)"
expect "the hint names the workflow file" log_has ".github/workflows/archfit.yaml as that workflow's own job"

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

for superseded in stale_run stale_head; do
	begin "409 $superseded: superseded, not a failure"
	on_push "$c2"
	start_app "[{\"status\": 409, \"body\": {\"error\": \"$superseded\"}}]"
	run_action "$origin"
	expect_eq "the action succeeds" 0 "$action_rc"
	expect_eq "one upload" 1 "$(requests upload)"
	expect "the notice says the upload was superseded" log_has "409 $superseded: a newer run, head or merge group supersedes this upload"
	expect_eq "app-status" 409 "$(out app-status)"
done

begin "explicit audience"
on_push "$c2"
start_app "[$ok_answer]"
export ARCHFIT_AUDIENCE=https://archfit.example
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "the token audience is the input, URL-encoded" \
	"api-version=2.0&audience=https%3A%2F%2Farchfit.example" "$(token_query)"

begin "result over the App's 5 MiB cap: refused before sending"
on_push "$c2"
start_app "[$ok_answer]"
{
	cat "$results/push-at-tip.json"
	head -c 5300000 /dev/zero | tr '\0' ' '
} >"$case_dir/huge.json"
export FAKE_RESULT=$case_dir/huge.json
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect "the error names the cap" log_has "accepts at most 5242880"

begin "endpoint without id-token permission"
on_push "$c2"
start_app "[$ok_answer]"
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect_eq "no upload" 0 "$(requests upload)"
expect "the error names the permission" log_has "id-token: write"

# --- Engine identity: the one engine this release pins --------------------------------

for unsupported in v3.4.0 v4.0.0 v4.0.0-rc.2; do
	begin "engine $unsupported is refused before the checkout"
	on_push "$c2"
	export ARCHFIT_ENGINE_VERSION=$unsupported
	run_action "$origin"
	expect_eq "the action fails" 1 "$action_rc"
	expect "the error names the one supported engine" log_has "this action runs engine $ENGINE_VERSION only"
	expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"
	expect_eq "no container ran" 0 "$(engine_calls)"
done

begin "an image tag is refused before any work"
on_push "$c2"
export ARCHFIT_IMAGE_DIGEST=v4.0.0-rc.1
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error refuses tags" log_has "tags are refused"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

for arch in X64 ARM64; do
	begin "engine-version and image-digest omitted on $arch: the pinned engine and its digest"
	on_push "$c2"
	unset ARCHFIT_ENGINE_VERSION ARCHFIT_IMAGE_DIGEST
	case $arch in
	X64) platform=linux/amd64 pinned=$(lib_constant ENGINE_DIGEST_AMD64) ;;
	ARM64) platform=linux/arm64 pinned=$(lib_constant ENGINE_DIGEST_ARM64) ;;
	esac
	export RUNNER_ARCH=$arch FAKE_PLATFORM=$platform
	start_app "[$ok_answer]"
	run_action "$origin"
	expect_eq "the action succeeds" 0 "$action_rc"
	expect_eq "prepare resolves the pinned engine" "$ENGINE_VERSION $pinned" "$(out engine-version) $(out image-digest)"
	expect_eq "the envelope names them" "$ENGINE_VERSION $pinned $platform" \
		"$(envelope_field engine_version) $(envelope_field image_digest) $(envelope_field platform)"
	expect "the image is pulled by that digest" json_ok \
		'.image == $i' "$(engine_call check)" --arg i "ghcr.io/alexei-led/archfit@$pinned"
done

begin "image-digest omitted on a runner without an engine image: refused before the checkout"
on_push "$c2"
unset ARCHFIT_IMAGE_DIGEST
export RUNNER_ARCH=X86
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names the architecture" log_has "runner architecture 'X86' has no engine image"
expect "nothing was checked out" test ! -e "$GITHUB_WORKSPACE"

begin "an image of another engine version is refused before analysis"
on_push "$c2"
export FAKE_ENGINE_VERSION=v3.4.0
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names both versions" log_has "is engine v3.4.0, not $ENGINE_VERSION"
expect_eq "only the version probe ran" 1 "$(engine_calls)"

begin "an image for another platform than the runner is refused before any container"
on_push "$c2"
export FAKE_PLATFORM=linux/arm64
run_action "$origin"
expect_eq "the action fails" 1 "$action_rc"
expect "the error names both platforms" log_has "built for linux/arm64, but this runner is linux/amd64"
expect_eq "no container ran" 0 "$(engine_calls)"

prepare_with_endpoint() { # ENDPOINT: run prepare.sh alone; sets action_rc
	on_push "$c2"
	action_rc=0
	ARCHFIT_ENDPOINT=$1 bash "$root/scripts/prepare.sh" >"$case_dir/log" 2>&1 || action_rc=$?
}
for endpoint in http://archfit.example https://archfit.example/ http://127.0.0.1:8080/ "https://user:pw@archfit.example" ftp://archfit.example; do
	begin "endpoint '$endpoint' is refused"
	prepare_with_endpoint "$endpoint"
	expect_eq "prepare fails" 1 "$action_rc"
	expect "the error explains the endpoint" log_has "endpoint must"
done
for endpoint in https://archfit.example https://archfit.example/app http://127.0.0.1:8080 http://localhost; do
	begin "endpoint '$endpoint' is accepted"
	prepare_with_endpoint "$endpoint"
	expect_eq "prepare succeeds" 0 "$action_rc"
done

# --- No credentials reach the container ------------------------------------------------

# with_git_config NAME FILE KEY VALUE SHOWN: run the steps with KEY=VALUE planted in FILE
# (relative to the checkout's .git) between the checkout and the engine run.
with_git_config() {
	begin "credentials never reach the engine container: $1"
	on_push "$c2"
	action_rc=0
	{
		bash "$root/scripts/prepare.sh"
		checkout "$origin" "$(out ref)"
		mkdir -p "$(dirname "$GITHUB_WORKSPACE/.git/$2")"
		git config --file "$GITHUB_WORKSPACE/.git/$2" "$3" "$4"
		ARCHFIT_ENGINE_VERSION=$(out engine-version) ARCHFIT_IMAGE_DIGEST=$(out image-digest) bash "$root/scripts/run.sh"
	} >"$case_dir/log" 2>&1 || action_rc=$?
	expect_eq "the action fails" 1 "$action_rc"
	expect "the error names the file" log_has "keeps credentials in $5"
	expect_eq "no docker call" 0 "$(jq -s length "$FAKE_DOCKER_LOG")"
}
with_git_config "scoped extraheader" config http.https://github.com/.extraheader "AUTHORIZATION: basic c2VjcmV0" .git/config
with_git_config "plain extraheader" config http.extraheader "AUTHORIZATION: basic c2VjcmV0" .git/config
with_git_config "credential helper" config credential.helper store .git/config
with_git_config "url insteadOf" config url.https://x-access-token:secret@github.com/.insteadOf https://github.com/ .git/config
with_git_config "remote URL with userinfo" config remote.origin.url https://x-access-token:secret@github.com/acme/shop .git/config
with_git_config "submodule config" modules/lib/config http.extraheader "AUTHORIZATION: basic c2VjcmV0" .git/modules/lib/config

begin "a remote URL without userinfo is fine"
on_push "$c2"
action_rc=0
{
	bash "$root/scripts/prepare.sh"
	checkout "$origin" "$(out ref)"
	git -C "$GITHUB_WORKSPACE" config remote.origin.url https://github.com/acme/shop
	ARCHFIT_ENGINE_VERSION=$(out engine-version) ARCHFIT_IMAGE_DIGEST=$(out image-digest) bash "$root/scripts/run.sh"
} >"$case_dir/log" 2>&1 || action_rc=$?
expect_eq "the run succeeds" 0 "$action_rc"

# --- The validator itself: it must reject what the App's decoder rejects --------------

begin "the validator rejects envelopes the App's decoder or the header transport would reject"
reference=$tmp/pull_request.envelope
expect "the pull request envelope is valid" valid_envelope "$reference" ""
expect "the push envelope is valid" valid_envelope "$tmp/push.envelope" ""
expect "the merge group envelope is valid" valid_envelope "$tmp/merge_group.envelope" ""
expect "the re-run envelope is valid" valid_envelope "$tmp/rerun.envelope" ""
rejects() { # NAME: $case_dir/NAME.json must fail validation
	if "$validator" "$schema" "$case_dir/$1.json" >/dev/null 2>&1; then fail "rejects $1"; else pass "rejects $1"; fi
}
mutate() { # NAME JQ-FILTER [REFERENCE]
	jq -cj "$2" "${3:-$reference}" >"$case_dir/$1.json"
	rejects "$1"
}
edit() { # NAME FROM TO: textual mutations jq cannot express
	local text
	text=$(<"$reference")
	printf '%s' "${text/"$2"/"$3"}" >"$case_dir/$1.json"
	rejects "$1"
}
mutate extra-key '. + {workflow_ref: "acme/shop/.github/workflows/archfit.yaml@refs/heads/main"}'
mutate v1-kind '. + {kind: "report"}'
mutate v1-baseline-digest '. + {baseline_digest: ""}'
mutate v1-integration '. + {integration: "merged"}'
mutate missing-target-sha 'del(.target_sha)'
mutate missing-merge-base 'del(.merge_base_sha)'
mutate missing-policy-digest 'del(.policy_digest)'
mutate v1-schema-version '.schema_version = "archfit.report-envelope.v1"'
mutate dispatch-event '.event = "workflow_dispatch" | .pull_request = 0'
mutate string-run-id '.run_id |= tostring'
mutate zero-attempt '.run_attempt = 0'
mutate bare-payload-digest '.payload_digest |= ltrimstr("sha256:")'
mutate bare-policy-digest '.policy_digest |= ltrimstr("sha256:")'
mutate uppercase-head '.head_sha |= ascii_upcase'
mutate short-target-sha '.target_sha |= .[0:39]'
mutate target-ref-not-a-branch '.target_ref = "refs/tags/v1.0.0"'
mutate short-target-ref '.target_ref = "main"'
mutate platform-without-arch '.platform = "linux"'
mutate pull-request-zero '.pull_request = 0'
mutate push-with-pull-request '.event = "push"'
mutate merge-group-with-pull-request '.pull_request = 42' "$tmp/merge_group.envelope"
mutate null-target-sha '.target_sha = null'
edit exponent-run-id '"run_id":17654321098' '"run_id":1.7654321098e10'
edit fraction-attempt '"run_attempt":1,' '"run_attempt":1.0,'
edit duplicate-key '"platform"' "\"head_sha\":\"$f1\",\"platform\""
edit two-lines ',"event"' $',\n"event"'
edit oversized '"}' "\"$(printf '%9000s' '')}"
expect "rejects a payload the digest does not name" \
	bash -c '! "$1" "$2" "$3=$4" >/dev/null 2>&1' _ "$validator" "$schema" "$reference" "$results/fail.json"
expect "accepts the payload the digest names" valid_envelope "$reference" "$tmp/pull_request.result"

finish
