#!/usr/bin/env bash
# End-to-end check against the real pinned engine image; needs docker and network.
#
# Drives the action's steps (prepare, checkout, run, report) on a scratch Go repository
# with ghcr.io/alexei-led/archfit v2.3.1 for linux/amd64, the image the App's manifest
# names. It proves the identity the action derives, that the engine reads exactly the
# bundle bytes the envelope digests, that git history works through the read-only .git
# mount, and that a baseline the action captures is comparable for the next report run.
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
expect_eq "a blocked verdict fails an analysis-only job" 1 "$action_rc"
expect_eq "verdict" blocked "$(out verdict)"
expect_eq "engine_version is what the image reports" v2.3.1 "$(fact engine_version)"
expect_eq "platform is the image's" linux/amd64 "$(fact platform)"
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
expect_eq "baseline schema" archfit.baseline.v2 "$(jq -r .schema_version "$(out payload-file)")"
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

finish
