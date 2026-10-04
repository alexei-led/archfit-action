# shellcheck shell=bash
# Shared by the test scripts: assertions, a fixture repository, GitHub-like job
# environments, and a runner that drives the action's steps in action.yml order.
# The sourcing script sets tmp and reads action_rc; single-quoted $names are jq's.
# shellcheck disable=SC2016,SC2034,SC2154

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# ghcr.io/alexei-led/archfit v2.3.1, linux/amd64 manifest (index sha256:6bd35b7b…0351).
readonly ENGINE_DIGEST=sha256:7d4f73248865e11bbfe244cd477bd0ea8e8cbdc0b7fb2baade8e044b618b2793
passes=0 failures=0

pass() {
	passes=$((passes + 1))
	printf 'ok   %s\n' "$1"
}
fail() {
	failures=$((failures + 1))
	printf 'FAIL %s\n' "$1"
	[[ -z ${2:-} ]] || printf '     %s\n' "$2"
	[[ -z ${case_dir:-} || ! -f $case_dir/log ]] || sed 's/^/     | /' "$case_dir/log" | tail -n 15
}
# expect DESCRIPTION COMMAND... passes when COMMAND succeeds.
expect() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "want '$2', got '$3'"; fi; }
finish() {
	printf '\n%d passed, %d failed\n' "$passes" "$failures"
	((failures == 0))
}

build_validator() { # OUT: the envelope validator, built from tests/validate (go.sum pins it)
	(cd "$root/tests/validate" && go build -o "$1" .)
}

commit_all() { # DIR MESSAGE
	git -C "$1" -c core.safecrlf=false add -A
	git -C "$1" -c user.name=test -c user.email=test@example.com commit --quiet -m "$2"
}

# write_module DIR: the engine's single-module fixture, a Go module whose package a
# imports package b, and the policy that forbids exactly that dependency.
write_module() {
	mkdir -p "$1/pkg/a" "$1/pkg/b"
	printf 'module example.com/single\n\ngo 1.21\n' >"$1/go.mod"
	cat >"$1/pkg/a/a.go" <<'EOF'
package a

import "example.com/single/pkg/b"

// UseB calls the public API of module b.
func UseB() string { return b.Hello() }
EOF
	cat >"$1/pkg/b/b.go" <<'EOF'
package b

// Hello is the public API of module b.
func Hello() string { return "hello" }
EOF
	cat >"$1/.archfit.yaml" <<'EOF'
version: 2
modules:
  a:
    paths:
      - pkg/a/**
    owner: team-a
    subdomain: supporting
    volatility: medium
  b:
    paths:
      - pkg/b/**
    owner: team-b
    subdomain: core
    volatility: low
rules:
  - id: no_direct_b_dependency
    type: forbidden_dependency
    gate: fail
    from: pkg/a/**
    to: pkg/b/**
languages:
  typescript:
    enabled: false
  python:
    enabled: false
analyzers:
  scip:
    enabled: false
  clones:
    enabled: false
  syntax:
    enabled: false
EOF
}

# new_case NAME: fresh directories and a GitHub-like job environment.
new_case() {
	case_dir=$(mktemp -d "$tmp/case.XXXXXX")
	printf -- '-- %s\n' "$1"
	export RUNNER_TEMP=$case_dir/runner GITHUB_OUTPUT=$case_dir/output GITHUB_STEP_SUMMARY=$case_dir/summary
	mkdir -p "$RUNNER_TEMP"
	: >"$GITHUB_OUTPUT"
	: >"$GITHUB_STEP_SUMMARY"
	export GITHUB_WORKSPACE=$case_dir/workspace GITHUB_REPOSITORY=acme/shop
	export GITHUB_RUN_ID=17654321098 GITHUB_RUN_ATTEMPT=1 RUNNER_ARCH=X64
	export ARCHFIT_ENGINE_VERSION=v2.3.1 ARCHFIT_IMAGE_DIGEST=$ENGINE_DIGEST
	unset ARCHFIT_MODE ARCHFIT_DISCOVER ARCHFIT_ENDPOINT ARCHFIT_AUDIENCE \
		ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
}

event_file() { # TEMPLATE JQ-FILTER [JQ ARGS...]: write the case's event payload
	jq "${@:3}" "$2" "$root/tests/events/$1.json" >"$case_dir/event.json"
	export GITHUB_EVENT_PATH=$case_dir/event.json
}
on_pull_request() { # HEAD BASE [HEAD_REPO]
	# GITHUB_SHA is the merge commit of a pull_request run; the action must never use it.
	export GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/42/merge \
		GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
	event_file pull_request '.pull_request.head.sha = $h | .pull_request.base.sha = $b
		| .pull_request.head.repo.full_name = $r' --arg h "$1" --arg b "$2" --arg r "${3:-acme/shop}"
}
on_push() { # SHA
	export GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_SHA=$1
	event_file push '.after = $s' --arg s "$1"
}
on_dispatch() { # SHA DISCOVER
	export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_SHA=$1 ARCHFIT_DISCOVER=$2
	event_file workflow_dispatch '.inputs.discover = $d' --arg d "$2"
}
on_unsupported() { # EVENT HEAD DEFAULT_BRANCH_TIP: an event the action must refuse
	export GITHUB_EVENT_NAME=$1 GITHUB_REF=refs/heads/main GITHUB_SHA=$3
	event_file workflow_run '.workflow_run.head_sha = $h' --arg h "$2"
}

# out NAME prints the last value the steps wrote for output NAME.
out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }

# checkout ORIGIN REF: what actions/checkout does with fetch-depth 0 and no credentials.
checkout() {
	git clone --quiet --no-local "$1" "$GITHUB_WORKSPACE"
	git -C "$GITHUB_WORKSPACE" checkout --quiet --detach "$2"
}

# run_action ORIGIN runs the action's steps as action.yml wires them; the artifact
# upload in between is GitHub's own action. Sets action_rc; the log is $case_dir/log.
run_action() {
	action_rc=0
	{
		bash "$root/scripts/prepare.sh" &&
			checkout "$1" "$(out ref)" &&
			ARCHFIT_MODE=$(out mode) bash "$root/scripts/run.sh" &&
			ARCHFIT_FACTS=$(out facts-file) bash "$root/scripts/report.sh"
	} >"$case_dir/log" 2>&1 || action_rc=$?
}

log_has() { grep -qF -- "$1" "$case_dir/log"; }
fact() { jq -r ".$1" "$(out facts-file)"; }
envelope_field() { jq -r ".$1" "$(out envelope-file)"; }
blob_sha256() { git -C "$1" cat-file blob "$2" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }
