#!/usr/bin/env bash
# Run the pinned archfit engine image on the checked-out commit.
#
# Trusted inputs. The engine reads .archfit.yaml, .archfit-baseline.json and
# .archfit-labels.yaml from the directory of its config. They are written from git
# blobs into RUNNER_TEMP, never taken from the working tree, and hashed before the
# container starts, so their digests name exactly the bytes the engine read. Blob
# bytes are also what the App reads through the contents API; working-tree bytes can
# differ under .gitattributes eol rules.
# On a pull request reported to the App, each file comes from the head commit when the
# pull request changes it (merge base..head, the diff behind GitHub's file list) and
# from the tip of the base branch otherwise. The App trusts a head digest only when a
# policy owner approved that exact head commit. Without an endpoint nobody checks that
# approval, so every file comes from the base tip. Push and dispatch runs read the
# files from the protected ref the run executed on.
#
# Container. The checkout is mounted at /src with .git read-only; each trusted input is
# mounted read-only over /bundle/<name>; /bundle itself is an empty writable directory
# for the engine's fact cache and a captured baseline. A re-anchor also reads the
# protected baseline, mounted read-only at /reference/.archfit-baseline.json: not under
# /bundle, where the engine writes the new one. HOME=/tmp, and nothing else: no
# token, no OIDC variable, no credential. The working tree stays writable because
# analyzers write there (`uv run` creates .venv and uv.lock in a Python project). .git
# is read-only so code that runs during analysis cannot plant git config or hooks for
# git on the runner to execute later. Reports are read from the engine's stdout into
# RUNNER_TEMP, outside every mount.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require git jq docker

readonly TRUSTED_INPUTS=(.archfit.yaml .archfit-baseline.json .archfit-labels.yaml)

mode=${ARCHFIT_MODE:?}
image_digest=${ARCHFIT_IMAGE_DIGEST:?}
pinned_version=${ARCHFIT_ENGINE_VERSION:?}
src=${GITHUB_WORKSPACE:?}
event=${GITHUB_EVENT_NAME:?}
endpoint=${ARCHFIT_ENDPOINT:-}
work=$(work_dir)
inputs=$work/inputs       # the materialized trusted inputs, mounted read-only one by one
reference=$work/reference # the protected baseline a re-anchor reads, mounted read-only
bundle=$work/bundle       # the engine's writable config directory
out=$work/out
engine_log=$out/engine.log
image=$ENGINE_IMAGE_REPO@$image_digest
mkdir -p "$inputs" "$reference" "$bundle" "$out"
: >"$work/inputs.tsv"

head="" base_sha="" merge_base="" pull_request=0 fork=false input_tip=""
engine_version="" platform="" verdict="" payload="" kind="" artifact="" report_file=""

resolve_revisions() {
	local base_ref head_repo checked_out
	case $event in
	pull_request)
		head=$(event_field .pull_request.head.sha)
		pull_request=$(event_field .pull_request.number)
		base_ref=$(event_field .pull_request.base.ref)
		head_repo=$(event_field .pull_request.head.repo.full_name)
		[[ $pull_request =~ ^[1-9][0-9]{0,8}$ ]] || die "the pull_request event carries no pull request number"
		# The App compares base_sha with the pull request's base.sha from GitHub's API, and
		# merge_base_sha with GitHub's merge base of that commit and the head. The event
		# payload carries the same base.sha; the fetched branch tip can be newer.
		base_sha=$(event_field .pull_request.base.sha)
		is_sha "$base_sha" || die "the pull_request event carries no base SHA"
		[[ $head_repo == "${GITHUB_REPOSITORY:?}" ]] || fork=true
		git -C "$src" cat-file -e "$base_sha^{commit}" 2>/dev/null ||
			die "base commit $base_sha is not in the fetched history"
		merge_base=$(git -C "$src" merge-base --all "$base_sha" "$head") ||
			die "no merge base between $base_sha and $head"
		# After criss-cross merges git has several best merge bases and GitHub's compare
		# picks one of them; the per-file input rule and the App's binding need exactly one.
		[[ $merge_base != *$'\n'* ]] ||
			die "$base_sha and $head have more than one merge base ($(tr '\n' ' ' <<<"$merge_base")); merge the base branch into the pull request so one merge base remains, then push"
		input_tip=$(git -C "$src" rev-parse --verify --quiet "refs/remotes/origin/$base_ref^{commit}") ||
			die "the base branch $base_ref was not fetched"
		;;
	*)
		head=${GITHUB_SHA:?}
		input_tip=$head
		;;
	esac
	checked_out=$(git -C "$src" rev-parse HEAD)
	[[ $checked_out == "$head" ]] || die "the checkout is at $checked_out, not at the analysed commit $head"
}

# Git config keys that carry or route credentials: auth headers, credential helpers,
# URL rewrites (which can embed a token) and conditional includes.
readonly CREDENTIAL_KEYS='^(http\.(.+\.)?extraheader|credential\..+|url\..+\.(push)?insteadof|includeif\..+)$'

# git_config_has_credentials ARGS... checks one config file (git config ARGS selects it).
git_config_has_credentials() {
	git "$@" --name-only --get-regexp "$CREDENTIAL_KEYS" >/dev/null 2>&1 && return 0
	# A remote URL with userinfo (https://user:token@host/...) carries the token itself.
	git "$@" --get-regexp '^remote\..+\.(push)?url$' 2>/dev/null |
		grep -Eq '^[^ ]+ [A-Za-z][A-Za-z0-9+.-]*://[^/@]*@'
}

# The container mounts .git, so a credential persisted in any of its config files, the
# repository's or a submodule's, would reach it.
assert_no_credentials() {
	local file
	git_config_has_credentials -C "$src" config --local &&
		die "the checkout keeps credentials in .git/config, where the engine container would read them; let this action check out the repository (it uses persist-credentials: false)"
	[[ -d $src/.git/modules ]] || return 0
	while IFS= read -r -d '' file; do
		git_config_has_credentials config --file "$file" &&
			die "the checkout keeps credentials in ${file#"$src/"}, where the engine container would read them; check out submodules without persisted credentials"
	done < <(find "$src/.git/modules" -type f -name config -print0)
	return 0
}

# materialize PATH [DIR] writes the trusted copy of PATH into DIR (the inputs directory
# by default) and records where it came from (base or head on a pull request, else ref).
# A PATH absent at the chosen commit leaves no file and an empty digest.
materialize() {
	local path=$1 dir=${2:-$inputs} rev=$input_tip from=ref rc=0 entry fmode ftype oid digest=""
	if [[ $event == pull_request ]]; then
		from=base
		# Head bytes only for an upload, where the App checks owner approval of the head.
		if [[ -n $endpoint ]]; then
			git -C "$src" diff --quiet --no-ext-diff "$merge_base" "$head" -- "$path" || rc=$?
			case $rc in
			0) ;;
			1) rev=$head from=head ;;
			*) die "git diff failed for $path" ;;
			esac
		fi
	fi
	rm -f "$dir/$path"
	entry=$(git -C "$src" ls-tree "$rev" -- "$path") || die "git ls-tree failed for $path at $rev"
	if [[ -n $entry ]]; then
		read -r fmode ftype oid <<<"${entry%%$'\t'*}"
		[[ $ftype == blob && ($fmode == 100644 || $fmode == 100755) ]] ||
			die "$path at $rev is not a regular file (git mode $fmode)"
		git -C "$src" cat-file blob "$oid" >"$dir/$path" || die "cannot read $path at $rev"
		digest=$(sha256_hex "$dir/$path")
	fi
	printf '%s\t%s\t%s\t%s\n' "$path" "$from" "$rev" "$digest" >>"$work/inputs.tsv"
}

# digest_of PATH prints the digest recorded when PATH was materialized ("" = absent).
digest_of() { awk -F'\t' -v p="$1" '$1 == p { d = $4 } END { print d }' "$work/inputs.tsv"; }
# source_of PATH prints the commit PATH was read from.
source_of() { awk -F'\t' -v p="$1" '$1 == p { r = $3 } END { print r }' "$work/inputs.tsv"; }

engine() {
	local name mounts=()
	for name in "${TRUSTED_INPUTS[@]}"; do
		[[ ! -f $inputs/$name ]] || mounts+=(--volume "$inputs/$name:/bundle/$name:ro")
	done
	[[ ! -f $reference/.archfit-baseline.json ]] ||
		mounts+=(--volume "$reference/.archfit-baseline.json:/reference/.archfit-baseline.json:ro")
	docker run --rm --pull never \
		--user "$(id -u):$(id -g)" \
		--cap-drop ALL --security-opt no-new-privileges \
		--env HOME=/tmp \
		--volume "$src:/src" \
		--volume "$src/.git:/src/.git:ro" \
		--volume "$bundle:/bundle" \
		${mounts[@]+"${mounts[@]}"} \
		--workdir /src \
		"$image" "$@"
}

# show_engine_log prints the engine's stderr. The text is repository-controlled, so
# workflow commands are suspended while it is printed.
show_engine_log() {
	[[ -s $engine_log ]] || return 0
	print_fenced "archfit engine log" "$engine_log"
}

# print_fenced TITLE FILE prints FILE in a group with workflow commands suspended, so the
# text cannot start a command of its own. The text is repository-controlled.
print_fenced() {
	local fence
	fence=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	printf '::group::%s\n::stop-commands::%s\n' "$1" "$fence"
	cat "$2"
	printf '\n::%s::\n::endgroup::\n' "$fence"
}

engine_failed() {
	show_engine_log
	die "$1"$'\n'"$(tail -n 20 "$engine_log" 2>/dev/null)"
}

# engine_identity pulls the image by digest (the registry content is verified against
# it) and reads the identity the App looks up in its manifest.
engine_identity() {
	local line word1 word2 runner_platform
	docker pull --quiet "$image" >/dev/null || die "could not pull $image"
	platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image") ||
		die "could not inspect $image"
	[[ $platform =~ ^[a-z0-9]+/[a-z0-9]+$ ]] || die "unexpected platform '$platform' for $image"
	# The App's manifest names one digest per platform; an image for another platform
	# runs emulated, or not at all, so it is refused before any container starts.
	case ${RUNNER_ARCH:-} in
	X64) runner_platform=linux/amd64 ;;
	ARM64) runner_platform=linux/arm64 ;;
	*) die "runner architecture '${RUNNER_ARCH:-unset}' is not one the engine image is built for (X64, ARM64)" ;;
	esac
	[[ $platform == "$runner_platform" ]] ||
		die "image $image_digest is built for $platform, but this runner is $runner_platform; pin the digest the App's manifest lists for $runner_platform"
	line=$(engine --version) || die "$image did not report its version"
	read -r word1 word2 engine_version _ <<<"$line"
	[[ $word1 == archfit && $word2 == version ]] || die "unexpected engine version output: $line"
	[[ $engine_version == "$pinned_version" ]] ||
		die "image $image_digest is engine $engine_version, not $pinned_version; pin the digest of the engine version you name"
}

# check STATE runs `archfit check` into STATE. The exit code is the verdict
# (0 healthy, 1 blocked, 2 needs_attention); 3 means no report was produced.
check() {
	local state=$1 rc=0 schema expected
	engine check --json --progress=none -c /bundle/.archfit.yaml --root /src >"$state" 2>"$engine_log" || rc=$?
	case $rc in
	0 | 1 | 2) ;;
	3) engine_failed "archfit exited 3: no report was produced (a configuration, usage or tool error)" ;;
	*) engine_failed "the engine container exited $rc" ;;
	esac
	show_engine_log
	schema=$(jq -r '.schema_version // ""' "$state" 2>/dev/null) || die "the engine output is not JSON"
	[[ $schema == "$STATE_SCHEMA" ]] ||
		die "the engine output declares schema_version '$schema'; this action carries $STATE_SCHEMA"
	verdict=$(jq -r '.verdict // ""' "$state")
	case $verdict in
	healthy) expected=0 ;;
	blocked) expected=1 ;;
	needs_attention) expected=2 ;;
	*) die "the report declares no known verdict ('$verdict')" ;;
	esac
	[[ $rc == "$expected" ]] || die "archfit exited $rc, but its report says $verdict"
}

# capture_baseline WHAT [ENGINE FLAGS...] runs `archfit baseline` and keeps the file it
# writes as the payload. Stdout (the engine's own messages, such as the temporary-waiver
# disclosure, and in a re-anchor the report) goes to a file that is printed in the log;
# stderr goes to the engine log.
capture_baseline() {
	local what=$1 captured=$bundle/.archfit-baseline.json
	shift
	rm -f "$captured"
	engine baseline "$@" -c /bundle/.archfit.yaml --root /src >"$out/engine.out" 2>"$engine_log" ||
		engine_failed "archfit could not $what"
	show_engine_log
	if [[ -s $out/engine.out ]]; then
		print_fenced "archfit engine output" "$out/engine.out"
	fi
	[[ -f $captured && ! -L $captured ]] || die "archfit wrote no baseline file"
	payload=$out/.archfit-baseline.json
	cp "$captured" "$payload"
}

# self_check_baseline: the capture is only useful when this image finds it comparable.
# Unaccepted findings may block (exit 1); only the reference status decides here.
self_check_baseline() {
	local status
	cp "$payload" "$inputs/.archfit-baseline.json"
	check "$out/archfit-state.json"
	status=$(jq -r '.gate_reference.status // ""' "$out/archfit-state.json")
	[[ $status == comparable ]] ||
		die "the captured baseline is not comparable in this image ($status): $(jq -r '(.gate_reference.reasons // []) | join("; ")' "$out/archfit-state.json")"
}

# show_reanchor_report keeps the engine's report as a file for the artifact and puts it in
# the step summary. The log already has it (capture_baseline). The text names rules,
# modules and paths of the repository, so the markdown fence is longer than any backtick
# run in the text. The summary is capped; the artifact holds the full report.
readonly SUMMARY_REPORT_MAX_BYTES=524288
show_reanchor_report() {
	local ticks='```' text=$out/engine.out
	report_file=$out/reanchor-report.txt
	cp "$text" "$report_file"
	while grep -qF -- "$ticks" "$text"; do ticks+='`'; done
	summary "#### Re-anchor report" "" "$ticks"
	head -c "$SUMMARY_REPORT_MAX_BYTES" "$text" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
	summary "" "$ticks"
	if (($(wc -c <"$text") > SUMMARY_REPORT_MAX_BYTES)); then
		summary "The report is longer than the summary shows; the archfit-baseline artifact holds all of it." ""
	fi
}

write_facts() {
	jq -n \
		--arg mode "$mode" --arg kind "$kind" --arg event "$event" \
		--arg head_sha "$head" --arg base_sha "$base_sha" --arg merge_base_sha "$merge_base" \
		--argjson pull_request "$pull_request" --argjson fork "$fork" \
		--arg engine_version "$engine_version" --arg image_digest "$image_digest" --arg platform "$platform" \
		--arg baseline_digest "$(digest_of .archfit-baseline.json)" \
		--arg labels_digest "$(digest_of .archfit-labels.yaml)" \
		--arg payload_file "$payload" --arg verdict "$verdict" \
		--rawfile inputs "$work/inputs.tsv" \
		'{mode: $mode, kind: $kind, event: $event,
		  head_sha: $head_sha, base_sha: $base_sha, merge_base_sha: $merge_base_sha,
		  pull_request: $pull_request, fork: $fork,
		  engine_version: $engine_version, image_digest: $image_digest, platform: $platform,
		  baseline_digest: $baseline_digest, labels_digest: $labels_digest,
		  payload_file: $payload_file, verdict: $verdict,
		  inputs: ($inputs | split("\n") | map(select(length > 0) | split("\t")
		    | {path: .[0], from: .[1], commit: .[2], sha256: .[3]}))}' \
		>"$work/facts.json"
	set_output facts-file "$work/facts.json"
	set_output payload-file "$payload"
	set_output artifact-name "$artifact"
	set_output report-file "$report_file"
	set_output verdict "$verdict"
}

write_summary() {
	local analysed="\`$head\` ($event)"
	[[ $event != pull_request ]] ||
		analysed="\`$head\` (pull request #$pull_request, merge base \`$merge_base\`)"
	summary "### archfit $mode" "" \
		"- Analysed: $analysed" \
		"- Engine: $engine_version, $platform, \`$image_digest\`" \
		"- Verdict: ${verdict:-none}" ""
	[[ -s $work/inputs.tsv ]] || return 0
	summary "| Trusted input | From | Commit | SHA-256 |" "| --- | --- | --- | --- |"
	local path from rev digest
	while IFS=$'\t' read -r path from rev digest; do
		[[ -z $digest ]] || digest="\`$digest\`"
		summary "| \`$path\` | $from | \`${rev:0:12}\` | ${digest:-absent} |"
	done <"$work/inputs.tsv"
	summary ""
}

resolve_revisions
assert_no_credentials

case $mode in
report)
	for path in "${TRUSTED_INPUTS[@]}"; do materialize "$path"; done
	# Without an App the base policy gates the pull request; a head that deletes it would
	# otherwise pass as "measured" against a policy it no longer carries.
	if [[ $event == pull_request && -z $endpoint && -f $inputs/.archfit.yaml ]] &&
		[[ -z $(git -C "$src" ls-tree "$head" -- .archfit.yaml) ]]; then
		die "this pull request deletes .archfit.yaml. Without an App endpoint no policy owner approves that, so the job fails; keep the policy, or report to the App so an owner can approve the deletion."
	fi
	if [[ ! -f $inputs/.archfit.yaml ]]; then
		notice "no .archfit.yaml at $(source_of .archfit.yaml); there is no policy to measure against. Dispatch this workflow with mode: discovery on the default branch to propose one."
		write_facts
		exit 0
	fi
	engine_identity
	payload=$out/archfit-state.json
	check "$payload"
	kind=report artifact=archfit-report
	;;
discovery)
	engine_identity
	payload=$out/archfit-policy.yaml
	engine config init --root /src --output - >"$payload" 2>"$engine_log" ||
		engine_failed "archfit could not draft a policy"
	show_engine_log
	[[ -s $payload ]] || die "archfit drafted an empty policy"
	kind=discovery artifact=archfit-policy
	;;
baseline)
	# A capture is a pure function of tree and policy: the engine reads no stored
	# baseline here, so only the policy and the labels are materialized.
	materialize .archfit.yaml
	materialize .archfit-labels.yaml
	[[ -f $inputs/.archfit.yaml ]] || die "no .archfit.yaml at $(source_of .archfit.yaml); a baseline needs a policy"
	engine_identity
	capture_baseline "capture a baseline"
	# The self-check reads the copy, mounted read-only like every other input. It is not
	# materialized, so the envelope's baseline_digest stays empty: the capture read no
	# stored baseline.
	self_check_baseline
	kind=baseline artifact=archfit-baseline
	;;
reanchor)
	# The protected baseline is the one input a re-anchor reads besides policy and labels.
	# Its digest is the envelope's baseline_digest: the App compares it with the protected
	# blob and checks the new file against it. It is materialized outside the bundle.
	materialize .archfit.yaml
	materialize .archfit-labels.yaml
	materialize .archfit-baseline.json "$reference"
	[[ -f $inputs/.archfit.yaml ]] || die "no .archfit.yaml at $(source_of .archfit.yaml); a re-anchor needs a policy"
	[[ -f $reference/.archfit-baseline.json ]] ||
		die "no .archfit-baseline.json at $(source_of .archfit-baseline.json); there is no baseline to re-anchor. Run mode: baseline for the first capture."
	engine_identity
	capture_baseline "re-anchor the baseline" --reanchor --from /reference/.archfit-baseline.json
	show_reanchor_report
	self_check_baseline
	kind=reanchor artifact=archfit-baseline
	;;
esac

write_facts
write_summary
printf 'archfit: %s %s verdict=%s payload=%s\n' "$mode" "$head" "${verdict:-none}" "$payload"
