#!/usr/bin/env bash
# End-to-end check against the real pinned engine image; needs docker and network.
#
# Drives the action's steps (prepare, checkout, run, report) on scratch Go repositories
# with the pinned platform image and no App endpoint. App admission is a separate gate.
# It proves the identity the action derives; that the engine judges with exactly the
# target tip's policy blob the action mounts; that the change, its merge base and the
# target tip work through the read-only .git mount, with the engine's own cache and an
# untracked file in the checkout; and the statuses of design 9.1 and 10.5: a pull request
# that passes, one that fails, one that edits the policy, a re-run after an owner's
# answer, a merge group, and a push at the tip with the repository state.
# With ARCHFIT_FIXTURES_OUT set (CI uploads it), the results tests/run.sh replays are
# written there as result/<name>.json.
# shellcheck disable=SC2016 # single-quoted $names are jq's
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/archfit-engine-smoke.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
schema=$root/schema/envelope.v2.schema.json
validator=$tmp/validate
build_validator "$validator"

git_as_test() { git -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }

# Fixture: main holds code and policy (c1, then c2, so the tip has a parent). pass (p1)
# adds a call a -> b, which the policy allows; deny (x1) adds a -> c, which a rule denies;
# graph (b1) adds b -> c, which no module declares; edit (e1) edits the policy. Groups
# for the queue of main are built on c2.
origin=$tmp/origin
git init --quiet -b main "$origin"
write_module "$origin"
commit_all "$origin" "code and policy"
printf '\n// Again calls b once more.\nfunc Again() string { return b.Hello() }\n' >>"$origin/pkg/a/a.go"
commit_all "$origin" "more code"
c2=$(git -C "$origin" rev-parse HEAD)
branch() { # NAME: a new branch from c2
	git -C "$origin" checkout --quiet -b "$1" "$c2"
}
branch pass
printf '\n// Twice calls b twice.\nfunc Twice() string { return UseB() + UseB() }\n' >>"$origin/pkg/a/a.go"
commit_all "$origin" "pass: a calls b again"
p1=$(git -C "$origin" rev-parse HEAD)
branch deny
printf 'package a\n\nimport "example.com/single/pkg/c"\n\n// UseC calls c.\nfunc UseC() string { return c.Hi() }\n' >"$origin/pkg/a/c.go"
commit_all "$origin" "deny: a calls c"
x1=$(git -C "$origin" rev-parse HEAD)
branch graph
printf 'package b\n\nimport "example.com/single/pkg/c"\n\n// Wrap calls c.\nfunc Wrap() string { return c.Hi() }\n' >"$origin/pkg/b/c.go"
commit_all "$origin" "graph: b calls c"
b1=$(git -C "$origin" rev-parse HEAD)
branch edit
printf '# loosened by the change\n' >>"$origin/.archfit.yaml"
commit_all "$origin" "edit: the policy"
e1=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet -b queue "$c2"
git_as_test -C "$origin" merge --quiet --no-ff -m "group: pass" "$p1" >/dev/null
g1=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" checkout --quiet main

# eol: the same code with a policy that git converts to CRLF in the working tree.
eol=$tmp/eol
git init --quiet -b main "$eol"
write_module "$eol"
printf '*.yaml text eol=crlf\n' >"$eol/.gitattributes"
commit_all "$eol" "code and policy, CRLF on checkout"
printf '// more\n' >>"$eol/pkg/b/b.go"
commit_all "$eol" "more code"
eol_tip=$(git -C "$eol" rev-parse HEAD)

# From here a failing check is recorded, not fatal.
set +e

export_result() { # NAME: keep the case's result for tests/run.sh
	[[ -n ${ARCHFIT_FIXTURES_OUT:-} ]] || return 0
	mkdir -p "$ARCHFIT_FIXTURES_OUT/result"
	cp "$(out payload-file)" "$ARCHFIT_FIXTURES_OUT/result/$1.json"
}
valid() { "$validator" "$schema" "$(out envelope-file)=$(out payload-file)" >"$case_dir/validator.out" 2>&1; }
result_has() { jq -e "$1" "${@:2}" "$(out payload-file)" >/dev/null; } # FILTER [JQ ARGS]
target_policy_digest() { printf 'sha256:%s' "$(blob_sha256 "$1" "$2:.archfit.yaml")"; }

new_case "push at the tip: pass, with the repository state"
on_push "$c2"
run_action "$origin"
expect_eq "the job passes" 0 "$action_rc"
expect_eq "status" pass "$(out verdict)"
expect "the engine reports its identity" result_has '.engine == ($v | ltrimstr("v"))' --arg v "$ENGINE_VERSION"
expect_eq "identity derived from the image" "$ENGINE_VERSION $ENGINE_PLATFORM $ENGINE_DIGEST" \
	"$(fact engine_version) $(fact platform) $(fact image_digest)"
expect "the result carries the repository state" result_has '.repository.state == "clean"'
expect_eq "the result names the checked commit" "$c2" "$(jq -r .head "$(out payload-file)")"
expect "the engine wrote its cache through the read-only .git" test -d "$GITHUB_WORKSPACE/.archfit-cache"
expect "the envelope conforms to the App schema" valid
export_result push-at-tip

new_case "pull request that passes: judged with the target tip's policy blob"
on_pull_request "$p1" "$c2"
run_action "$origin"
expect_eq "the job passes" 0 "$action_rc"
expect_eq "status" pass "$(out verdict)"
expect_eq "the engine judged with the bytes the action mounted" "$(target_policy_digest "$origin" "$c2")" "$(envelope_field policy_digest)"
expect "the result names the mounted policy" result_has '.policy.path == "/archfit/policy/.archfit.yaml"'
expect_eq "the result names the head and the merge base" "$p1 $c2" \
	"$(jq -r '"\(.head) \(.base)"' "$(out payload-file)")"
expect "no repository state on a pull request" result_has 'has("repository") | not'
expect "the envelope conforms to the App schema" valid
export_result pass

new_case "pull request that adds a denied dependency: fail"
on_pull_request "$x1" "$c2"
run_action "$origin"
expect_eq "the job fails" 1 "$action_rc"
expect_eq "status" fail "$(out verdict)"
expect "the rule is named" result_has '[.errors[].rule] | index("no-a-to-c") != null'
expect "the envelope conforms to the App schema" valid
export_result fail

new_case "pull request that edits the policy: unknown, judged by nothing it brings"
on_pull_request "$e1" "$c2"
run_action "$origin"
expect_eq "the job fails" 1 "$action_rc"
expect_eq "status" unknown "$(out verdict)"
expect "the engine says the policy differs from the target" result_has '.policy.differs and .policy.target == "refs/remotes/origin/main"'
expect "the envelope conforms to the App schema" valid
export_result policy-differs

new_case "merge group of the passing pull request: pass"
on_merge_group "$g1" "$c2"
run_action "$origin"
expect_eq "the job passes" 0 "$action_rc"
expect_eq "the group commit was checked" "$g1" "$(jq -r .head "$(out payload-file)")"
expect "the envelope conforms to the App schema" valid

new_case "an untracked file in the checkout: the read-only .git still gives a result"
on_pull_request "$p1" "$c2"
action_rc=0
{
	bash "$root/scripts/prepare.sh" &&
		checkout "$origin" "$(out ref)" &&
		mkdir -p "$GITHUB_WORKSPACE/build" && printf 'built\n' >"$GITHUB_WORKSPACE/build/out.txt" &&
		ARCHFIT_ENGINE_VERSION=$(out engine-version) ARCHFIT_IMAGE_DIGEST=$(out image-digest) bash "$root/scripts/run.sh" &&
		ARCHFIT_FACTS=$(out facts-file) bash "$root/scripts/report.sh"
} >"$case_dir/log" 2>&1 || action_rc=$?
expect_eq "the job passes" 0 "$action_rc"
expect_eq "status" pass "$(out verdict)"

# Design 10.5: a pull request waits for an owner; the answer lands on main as a
# policy-only commit; a re-run of the same event judges the same head by the new policy.
rerun=$tmp/rerun
git clone --quiet --bare "$origin" "$rerun"
new_case "pull request that adds an undeclared dependency: fail, it needs an owner"
on_pull_request "$b1" "$c2"
run_action "$rerun"
expect_eq "the job fails" 1 "$action_rc"
expect "the error asks an owner" result_has '[.errors[] | select(.rule == "graph" and .next.kind == "command")] | length > 0'
answer=$tmp/answer
git clone --quiet "$rerun" "$answer"
old=$(<"$answer/.archfit.yaml")
printf '%s\n' "${old/"    volatility: low
  c:"/"    volatility: low
    depends_on: [c]
  c:"}" >"$answer/.archfit.yaml"
commit_all "$answer" "main: an owner allows b -> c"
git -C "$answer" push --quiet origin main
answered=$(git -C "$answer" rev-parse HEAD)
rm -rf "$GITHUB_WORKSPACE" "$RUNNER_TEMP"
mkdir -p "$RUNNER_TEMP"
: >"$GITHUB_OUTPUT"
export GITHUB_RUN_ATTEMPT=2
run_action "$rerun"
expect_eq "the re-run passes" 0 "$action_rc"
expect_eq "status" pass "$(out verdict)"
expect_eq "the re-run read the new tip" "$answered" "$(fact target_sha)"
expect_eq "the engine judged with the answered policy" "$(target_policy_digest "$rerun" "$answered")" "$(envelope_field policy_digest)"
expect_eq "run_attempt" 2 "$(envelope_field run_attempt)"
expect "the envelope conforms to the App schema" valid

new_case "push at the tip of a repository that converts the policy to CRLF: unknown"
on_push "$eol_tip"
run_action "$eol"
expect_eq "the job fails" 1 "$action_rc"
expect_eq "status" unknown "$(out verdict)"
expect "the engine says the checkout's policy differs from the tip's blob" result_has '.policy.differs'
export_result eol-differs

finish
