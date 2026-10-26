#!/usr/bin/env bash
# Exercise the shipped report stage, not an engine or an App approval path.
# SOURCE.md documents the genuine released-image captures and their hashes.
# Facts are synthetic transport metadata; their envelope proves no executed identity.
# shellcheck disable=SC2016 # single-quoted $names are jq's
set -euo pipefail
# shellcheck source=tests/helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/archfit-report-evidence.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fixtures=$root/tests/fixtures/required-evidence
attention=$fixtures/optional-attention.json
missing=$fixtures/missing-compiler.json

sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
report_case() { # NAME PAYLOAD EXPECTED_RC [ERROR]
	new_case "$1"
	mkdir -p "$RUNNER_TEMP/archfit"
	jq -n --arg payload "$2" --arg verdict "$(jq -r '.verdict' "$2")" \
		'{mode: "report", kind: "report", fork: false, payload_file: $payload, verdict: $verdict,
		  event: "push", pull_request: 0, head_sha: ("1" * 40), base_sha: "", merge_base_sha: "",
		  engine_version: "v3.2.3", platform: "linux/arm64",
		  image_digest: "sha256:54f6bf1ec99be6f4bdc21ca59e16d3dd65fb5b31a2c2af6c932ad556c89a220c",
		  baseline_digest: "", labels_digest: ""}' >"$case_dir/facts.json"
	local rc=0
	ARCHFIT_FACTS=$case_dir/facts.json bash "$root/scripts/report.sh" >"$case_dir/log" 2>&1 || rc=$?
	expect_eq "report stage exit" "$3" "$rc"
	expect "the envelope survives the local gate" test -s "$(out envelope-file)"
	expect_eq "no upload status" "" "$(out app-status)"
	[[ -z ${4:-} ]] || expect "the error explains the local gate" log_has "$4"
}

expect_eq "missing-compiler capture hash" \
	acde9deda04172707184b6f61c10ee866ecc166aa4c94fb8f2e57f6b7274cce7 "$(sha_of "$missing")"
expect_eq "optional-attention capture hash" \
	5200d5bcf764fcfed75fd427cae7720a67ff361824b4d134850112c5d11715e6 "$(sha_of "$attention")"

report_case "genuine optional attention: hard gates pass, empty required rules omitted" "$attention" 0
report_case "genuine missing compiler: required evidence unavailable" "$missing" 1 "required architecture evidence"

# Mutations below are negative/shape tests, never represented as engine captures.
jq '.decision.hard_gates = "unmeasured"' "$attention" >"$tmp/unmeasured.json"
report_case "unmeasured hard gates without a rule list fail" "$tmp/unmeasured.json" 1 "required architecture evidence"
jq '.decision.hard_gates = "pass"' "$missing" >"$tmp/required-gap.json"
report_case "required-rule gaps fail even if hard_gates says pass" "$tmp/required-gap.json" 1 "required architecture evidence"
jq '.decision.active_blockers = 1' "$attention" >"$tmp/active-blocker.json"
report_case "active blockers cannot pass with optional attention" "$tmp/active-blocker.json" 1 "required architecture evidence"
jq '.verdict = "healthy"' "$missing" >"$tmp/healthy-gap.json"
report_case "a healthy verdict cannot conceal missing evidence" "$tmp/healthy-gap.json" 1 "required architecture evidence"

for filter in \
	'del(.decision)' \
	'.decision = null' \
	'.decision = []' \
	'.decision = "pass"' \
	'.decision = {}' \
	'del(.decision.hard_gates)' \
	'.decision.hard_gates = null' \
	'.decision.hard_gates = "unknown"' \
	'.decision.hard_gates = true' \
	'.decision.unevaluated_required_rules = null' \
	'.decision.unevaluated_required_rules = {}' \
	'.decision.unevaluated_required_rules = ""' \
	'.decision.unevaluated_required_rules = false' \
	'del(.decision.active_blockers)' \
	'.decision.active_blockers = "0"' \
	'.decision.attention_dimensions = -1' \
	'.decision.unknown_dimensions = 0.5'; do
	jq "$filter" "$attention" >"$tmp/malformed.json"
	report_case "malformed decision: $filter" "$tmp/malformed.json" 1 "missing or invalid decision evidence"
done

cat "$missing" "$attention" >"$tmp/multiple.json"
report_case "multiple JSON reports cannot hide an evidence gap" "$tmp/multiple.json" 1 "missing or invalid decision evidence"

finish
