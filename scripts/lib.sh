# shellcheck shell=bash
# Helpers shared by the action's step scripts. Sourced, never executed.
# shellcheck disable=SC2034 # the constants are read by the scripts that source this file

# The engine image. The image-digest input selects the build inside it.
readonly ENGINE_IMAGE_REPO=ghcr.io/alexei-led/archfit
# The only engine release this action runs (the App's manifest names its image digests).
readonly SUPPORTED_ENGINE_VERSION=v3.0.0
# The engine state contract this action carries (`archfit check --json`).
readonly STATE_SCHEMA=archfit.architecture-state.v1

die() {
	printf '::error::%s\n' "$(escape "$*")" >&2
	exit 1
}

notice() { printf '::notice::%s\n' "$(escape "$*")"; }

# escape encodes a workflow-command message on one line, so text that came from
# the engine, the repository or the App cannot start a command of its own.
escape() {
	local s=$1
	s=${s//'%'/'%25'}
	s=${s//$'\r'/'%0D'}
	s=${s//$'\n'/'%0A'}
	printf '%s' "$s"
}

# set_output NAME VALUE writes one single-line step output.
set_output() {
	[[ $2 != *[$'\r\n']* ]] || die "step output $1 must be one line"
	printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"
}

summary() { printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }

# sha256_hex FILE prints the bare lowercase hex SHA-256 of the file's bytes.
sha256_hex() {
	local sum
	sum=$(sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") || return 1
	printf '%s' "${sum%% *}"
}

is_sha() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }

# event_field FILTER prints a field of the event payload, or nothing when it is absent.
event_field() { jq -r "$1 // empty" "${GITHUB_EVENT_PATH:?}"; }

# work_dir holds this run's bundle, payload and envelope: under RUNNER_TEMP, outside
# the checkout that the engine container sees.
work_dir() { printf '%s/archfit' "${RUNNER_TEMP:?RUNNER_TEMP is not set}"; }

require() {
	local tool
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || die "$tool is required and was not found on PATH"
	done
}
