#!/usr/bin/env bash
# End-to-end check against the real pinned engine image; needs docker and network.
#
# Drives the action's steps (prepare, checkout, run, report) on a scratch Go repository
# with the released native v3.4.0 platform image. App admission is a separate gate.
# It proves the identity the action derives, that the engine reads exactly the
# bundle bytes the envelope digests, that git history works through the read-only .git
# mount, that a baseline the action captures is comparable for the next report run, and
# that a pull request's --base comparison works through the mounts the action gives it.
# shellcheck disable=SC2016 # single-quoted $names are jq's
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/archfit-engine-smoke.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
schema=$root/schema/envelope.v1.schema.json
validator=$tmp/validate
build_validator "$validator"

origin=$tmp/origin
git init --quiet -b main "$origin"
write_module "$origin"
commit_all "$origin" "code and policy"
printf '\n// Again calls b once more.\nfunc Again() string { return b.Hello() }\n' >>"$origin/pkg/a/a.go"
commit_all "$origin" "more code"
head=$(git -C "$origin" rev-parse HEAD)

# From here a failing check is recorded, not fatal.
set +e

new_case "report without an endpoint: the forbidden dependency blocks"
on_push "$head"
run_action "$origin"
payload=$(out payload-file)
if [[ -n ${ARCHFIT_FIXTURES_OUT:-} ]]; then
	mkdir -p "$ARCHFIT_FIXTURES_OUT"
	cp "$payload" "$ARCHFIT_FIXTURES_OUT/state.json"
	cp "$(out envelope-file)" "$ARCHFIT_FIXTURES_OUT/envelope.json"
fi
expect_eq "a blocked verdict fails an analysis-only job" 1 "$action_rc"
expect_eq "verdict" blocked "$(out verdict)"
expect_eq "engine_version is what the image reports" v3.4.0 "$(fact engine_version)"
expect_eq "platform is the image's" "$ENGINE_PLATFORM" "$(fact platform)"
expect_eq "config_hash is the digest of the policy blob the action materialized" \
	"$(blob_sha256 "$origin" "$head:.archfit.yaml")" "$(jq -r .comparison.config_hash "$payload")"
expect "git history is readable through the read-only .git mount" \
	test "$(jq -r .measurement.history_depth "$payload")" -ge 1
expect "the envelope conforms to the App schema" "$validator" "$schema" "$(out envelope-file)=$payload"
expect "repair commands name the container layout" grep -qF -- '-c /bundle/.archfit.yaml --root /src' "$payload"
expect "the engine left tracked files unchanged" git -C "$GITHUB_WORKSPACE" diff --quiet

new_case "baseline: captured in the image and comparable there"
on_push "$head"
export ARCHFIT_MODE=baseline
run_action "$origin"
expect_eq "the capture succeeds" 0 "$action_rc"
expect_eq "baseline schema" archfit.baseline.v3 "$(jq -r .schema_version "$(out payload-file)")"
expect "a v3.4.0 capture stores neither dimensions nor hard-gate IDs" \
	jq -e '.state | (has("dimensions") or has("hard_gate_finding_ids")) | not' "$(out payload-file)"
expect "capture omits an unmeasured encapsulation reference" \
	jq -e '.metrics | has("encapsulation") | not' "$(out payload-file)"
expect "capture retains the genuinely measured zero cycle reference" \
	jq -e '.metrics.cycle.value == 0 and .metrics.cycle.version == "cycle.v1"' "$(out payload-file)"
if [[ -n ${ARCHFIT_FIXTURES_OUT:-} ]]; then
	cp "$(out payload-file)" "$ARCHFIT_FIXTURES_OUT/captured-baseline.json"
fi
cp "$(out payload-file)" "$tmp/captured.json"

new_case "report with the committed baseline: accepted debt no longer blocks"
cp "$tmp/captured.json" "$origin/.archfit-baseline.json"
commit_all "$origin" "accept the captured baseline"
head=$(git -C "$origin" rev-parse HEAD)
on_push "$head"
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect_eq "gate_reference" comparable "$(jq -r .gate_reference.status "$(out payload-file)")"
expect_eq "baseline_digest is the committed blob's" \
	"$(blob_sha256 "$origin" "$head:.archfit-baseline.json")" "$(envelope_field baseline_digest)"
expect "the envelope conforms to the App schema" "$validator" "$schema" "$(out envelope-file)=$(out payload-file)"

new_case "reanchor: the pinned engine carries the committed baseline forward and it stays comparable"
on_dispatch "$head"
export ARCHFIT_MODE=reanchor
run_action "$origin"
expect_eq "the action succeeds: the self-check finds the re-anchored file comparable" 0 "$action_rc"
expect_eq "baseline schema" archfit.baseline.v3 "$(jq -r .schema_version "$(out payload-file)")"
expect "the engine's report names what it kept" grep -q '^re-anchor: kept' "$(out report-file)"
expect_eq "artifact name" archfit-baseline "$(out artifact-name)"
expect "the re-anchored file stores neither dimensions nor hard-gate IDs" \
	jq -e '.state | (has("dimensions") or has("hard_gate_finding_ids")) | not' "$(out payload-file)"

# The stored fixture is a v3.0.0 baseline that still carries both fields. Re-anchoring it
# here is where tests/fixtures/reanchored-baseline.json and reanchor-report.txt come
# from: with ARCHFIT_FIXTURES_OUT set (CI uploads it), the outputs are written there.
new_case "reanchor of a stored v3.0.0 baseline: it loads, and the new file drops the old fields"
cp "$root/tests/fixtures/stored-baseline.json" "$origin/.archfit-baseline.json"
commit_all "$origin" "store a v3.0.0 baseline"
head=$(git -C "$origin" rev-parse HEAD)
on_dispatch "$head"
export ARCHFIT_MODE=reanchor
run_action "$origin"
expect_eq "the action succeeds" 0 "$action_rc"
expect "the stored file carries both fields (fixture sanity)" \
	jq -e '.state | has("dimensions") and has("hard_gate_finding_ids")' "$root/tests/fixtures/stored-baseline.json"
expect "the re-anchored file stores neither" \
	jq -e '.state | (has("dimensions") or has("hard_gate_finding_ids")) | not' "$(out payload-file)"
if [[ -n ${ARCHFIT_FIXTURES_OUT:-} ]]; then
	mkdir -p "$ARCHFIT_FIXTURES_OUT"
	cp "$(out payload-file)" "$ARCHFIT_FIXTURES_OUT/reanchored-baseline.json"
	cp "$(out report-file)" "$ARCHFIT_FIXTURES_OUT/reanchor-report.txt"
fi

# A pull request that adds the forbidden dependency: main has package a without the
# import, the feature branch adds it.
pr=$tmp/pr
git init --quiet -b main "$pr"
write_module "$pr"
printf 'package a\n\n// UseB is not wired to b yet.\nfunc UseB() string { return "" }\n' >"$pr/pkg/a/a.go"
commit_all "$pr" "code and policy, no dependency"
pr_base=$(git -C "$pr" rev-parse HEAD)
git -C "$pr" checkout --quiet -b feature
write_module "$pr"
commit_all "$pr" "feature: a calls b"
pr_head=$(git -C "$pr" rev-parse HEAD)
git -C "$pr" checkout --quiet main

new_case "pull request: the engine marks the dependency the pull request adds as introduced"
on_pull_request "$pr_head" "$pr_base"
run_action "$pr"
payload=$(out payload-file)
expect_eq "the blocked verdict fails an analysis-only job" 1 "$action_rc"
expect "the comparison ran: no fallback" test -z "$(grep -F 'origin is missing' "$case_dir/log")"
expect_eq "origin_status" comparable "$(jq -r .comparison.origin_status "$payload")"
expect "the forbidden dependency is introduced" jq -e \
	'[.findings[] | select(.rule_id == "no_direct_b_dependency")] as $f
	 | ($f | length) > 0 and all($f[]; .origin == "introduced")
	 and ([$f[].id] - .comparison.introduced_finding_ids) == []' "$payload"
expect "the envelope conforms to the App schema" "$validator" "$schema" "$(out envelope-file)=$payload"
expect "the base worktree is gone from the checkout" test ! -e "$GITHUB_WORKSPACE/.archfit-cache"
expect "the host .git/worktrees stays empty" test -z "$(ls -A "$GITHUB_WORKSPACE/.git/worktrees")"

finish
