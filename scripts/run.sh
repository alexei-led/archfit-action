#!/usr/bin/env bash
# Run the pinned archfit engine image on the checked-out commit.
#
# Trusted inputs. The engine reads .archfit.yaml, .archfit-baseline.json and
# .archfit-labels.yaml from the directory of its config. They are written from git
# blobs into a bundle outside the checkout, never taken from the working tree, and
# hashed before the container starts, so their digests name exactly the bytes the
# engine read. Blob bytes are also what the App reads through the contents API;
# working-tree bytes can differ under .gitattributes eol rules.
# On a pull request each file comes from the head commit when the pull request
# changes it (merge base..head, the diff behind GitHub's file list) and from the tip
# of the base branch otherwise. The App trusts a head digest only when a policy owner
# approved that exact head commit. Every other event reads the files from the
# protected ref the run executed on.
#
# Container. The checkout is mounted at /src with .git read-only, the bundle at
# /bundle, HOME=/tmp, and nothing else: no token, no OIDC variable, no credential.
# The working tree stays writable because analyzers write there (`uv run` creates
# .venv and uv.lock in a Python project). .git is read-only so code that runs during
# analysis cannot plant git config or hooks for git on the runner to execute later.
# Reports are read from the engine's stdout into RUNNER_TEMP, outside every mount.
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
work=$(work_dir)
bundle=$work/bundle
out=$work/out
engine_log=$out/engine.log
image=$ENGINE_IMAGE_REPO@$image_digest
mkdir -p "$bundle" "$out"
: >"$work/inputs.tsv"

head="" base_sha="" merge_base="" pull_request=0 fork=false input_tip=""
engine_version="" platform="" verdict="" payload="" kind="" artifact=""

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
		merge_base=$(git -C "$src" merge-base "$base_sha" "$head") ||
			die "no merge base between $base_sha and $head"
		input_tip=$(git -C "$src" rev-parse --verify --quiet "refs/remotes/origin/$base_ref^{commit}") ||
			die "the base branch $base_ref was not fetched"
		;;
	workflow_run)
		# Unsupported by the App (it answers unsupported_event); still state honestly
		# which commit was analysed and read the inputs from the default branch.
		head=$(event_field .workflow_run.head_sha)
		input_tip=${GITHUB_SHA:?}
		;;
	*)
		head=${GITHUB_SHA:?}
		input_tip=$head
		;;
	esac
	checked_out=$(git -C "$src" rev-parse HEAD)
	[[ $checked_out == "$head" ]] || die "the checkout is at $checked_out, not at the analysed commit $head"
}

# The container mounts .git, so a credential persisted in .git/config would reach it.
assert_no_credentials() {
	if git -C "$src" config --local --name-only \
		--get-regexp '^(http\..+\.extraheader|includeif\..+|credential\..+)$' >/dev/null 2>&1; then
		die "the checkout keeps credentials in .git/config, where the engine container would read them; let this action check out the repository (it uses persist-credentials: false)"
	fi
}

# materialize PATH writes the trusted copy of PATH into the bundle and records where it
# came from (base or head on a pull request, else ref). A PATH absent at the chosen
# commit leaves no file and an empty digest.
materialize() {
	local path=$1 rev=$input_tip from=ref rc=0 entry fmode ftype oid digest=""
	if [[ $event == pull_request ]]; then
		from=base
		git -C "$src" diff --quiet --no-ext-diff "$merge_base" "$head" -- "$path" || rc=$?
		case $rc in
		0) ;;
		1) rev=$head from=head ;;
		*) die "git diff failed for $path" ;;
		esac
	fi
	rm -f "$bundle/$path"
	entry=$(git -C "$src" ls-tree "$rev" -- "$path") || die "git ls-tree failed for $path at $rev"
	if [[ -n $entry ]]; then
		read -r fmode ftype oid <<<"${entry%%$'\t'*}"
		[[ $ftype == blob && ($fmode == 100644 || $fmode == 100755) ]] ||
			die "$path at $rev is not a regular file (git mode $fmode)"
		git -C "$src" cat-file blob "$oid" >"$bundle/$path" || die "cannot read $path at $rev"
		digest=$(sha256_hex "$bundle/$path")
	fi
	printf '%s\t%s\t%s\t%s\n' "$path" "$from" "$rev" "$digest" >>"$work/inputs.tsv"
}

# digest_of PATH prints the digest recorded when PATH was materialized ("" = absent).
digest_of() { awk -F'\t' -v p="$1" '$1 == p { d = $4 } END { print d }' "$work/inputs.tsv"; }

engine() {
	docker run --rm --pull never \
		--user "$(id -u):$(id -g)" \
		--cap-drop ALL --security-opt no-new-privileges \
		--env HOME=/tmp \
		--volume "$src:/src" \
		--volume "$src/.git:/src/.git:ro" \
		--volume "$bundle:/bundle" \
		--workdir /src \
		"$image" "$@"
}

# show_engine_log prints the engine's stderr. The text is repository-controlled, so
# workflow commands are suspended while it is printed.
show_engine_log() {
	[[ -s $engine_log ]] || return 0
	local fence
	fence=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	printf '::group::archfit engine log\n::stop-commands::%s\n' "$fence"
	cat "$engine_log"
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
	if [[ ! -f $bundle/.archfit.yaml ]]; then
		notice "no .archfit.yaml at $input_tip; there is no policy to measure against. Dispatch this workflow with discover: true on the default branch to propose one."
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
	[[ -f $bundle/.archfit.yaml ]] || die "no .archfit.yaml at $input_tip; a baseline needs a policy"
	engine_identity
	engine baseline -c /bundle/.archfit.yaml --root /src >"$engine_log" 2>&1 ||
		engine_failed "archfit could not capture a baseline"
	show_engine_log
	captured=$bundle/.archfit-baseline.json
	[[ -f $captured && ! -L $captured ]] || die "archfit wrote no baseline file"
	payload=$out/.archfit-baseline.json
	cp "$captured" "$payload"
	# The capture is only useful when this image finds it comparable.
	check "$out/archfit-state.json"
	status=$(jq -r '.gate_reference.status // ""' "$out/archfit-state.json")
	[[ $status == comparable ]] ||
		die "the captured baseline is not comparable in this image ($status): $(jq -r '(.gate_reference.reasons // []) | join("; ")' "$out/archfit-state.json")"
	artifact=archfit-baseline
	;;
esac

write_facts
write_summary
printf 'archfit: %s %s verdict=%s payload=%s\n' "$mode" "$head" "${verdict:-none}" "$payload"
