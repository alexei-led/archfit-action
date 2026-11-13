#!/usr/bin/env bash
# Run the pinned archfit engine image on the checked-out commit: one `archfit check`.
#
# Target and policy. The policy on the target branch is the approved policy (design 9.1).
# The target tip is the remote-tracking ref that actions/checkout (fetch-depth 0) fetched
# in this run: the pull request's base branch, the pushed branch, or the default branch for
# a merge group. A re-run fetches again, so it reads the tip as it is then: a policy that
# changed on the target since the first run judges the same head (design 10.5). The engine
# gets the full ref, never origin/<branch>, which a tag of that name would win.
# When the change (merge base..head) leaves .archfit.yaml alone, the tip's blob is written
# from git objects into RUNNER_TEMP, mounted read-only and passed with --policy: never the
# working tree, whose bytes eol rules can change. When the change edits the policy, or the
# head is the tip itself (a push at the tip, whose tree holds the tip's policy), the engine
# reads the checkout's file and compares it with the tip's: a difference is unknown, with
# the record that restores the file. At the tip the result also carries the repository state.
#
# Checked commit. A pull request is checked at its head, the commit the App binds the
# result to (the workflow run's head_sha); the change is what the head adds to its merge
# base with the target tip. A push is checked at the pushed commit, a merge group at the
# event's merge_group.head_sha, which prepare.sh checked against GITHUB_SHA and GITHUB_REF;
# the group's base must be an ancestor of it and of the default branch.
#
# Container. Git trusts only /src through fixed command-environment config: bind mount
# ownership can differ from the runner UID. No host/global Git config is changed. The
# checkout is mounted at /src with .git read-only, and the policy copy read-only outside
# /src. Only fixed HOME/Git settings are passed: no token, OIDC variable, credential, or
# copied host environment. The working tree stays writable: the engine keeps its cache in
# .archfit-cache, and target build tools can write there. .git is read-only so code that
# runs during analysis cannot plant git config or hooks for git on the runner to execute
# later. The result is read from the engine's stdout into RUNNER_TEMP, outside every mount.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require git jq docker

readonly POLICY=.archfit.yaml
# Where the container sees the target's policy copy: outside /src, so it is no file of the change.
readonly POLICY_MOUNT=/archfit/policy/.archfit.yaml

image_digest=${ARCHFIT_IMAGE_DIGEST:?}
pinned_version=${ARCHFIT_ENGINE_VERSION:?}
src=${GITHUB_WORKSPACE:?}
event=${GITHUB_EVENT_NAME:?}
work=$(work_dir)
out=$work/out
engine_log=$out/engine.log
policy_copy=$work/policy/$POLICY # the target tip's policy blob, mounted read-only with --policy
image=$ENGINE_IMAGE_REPO@$image_digest
mkdir -p "$out" "$(dirname "$policy_copy")"

head="" target_branch="" target_sha="" merge_base="" group_base="" pull_request=0 fork=false
policy_source="" policy_digest="" engine_version="" platform="" status="" payload=""

resolve_revisions() {
	local head_repo checked_out
	case $event in
	pull_request)
		head=$(event_field .pull_request.head.sha)
		pull_request=$(event_field .pull_request.number)
		target_branch=$(event_field .pull_request.base.ref)
		head_repo=$(event_field .pull_request.head.repo.full_name)
		[[ $pull_request =~ ^[1-9][0-9]{0,8}$ ]] || die "the pull_request event carries no pull request number"
		[[ $head_repo == "${GITHUB_REPOSITORY:?}" ]] || fork=true
		;;
	merge_group)
		head=$(event_field .merge_group.head_sha)
		group_base=$(event_field .merge_group.base_sha)
		target_branch=$(event_field .merge_group.base_ref)
		target_branch=${target_branch#refs/heads/}
		;;
	push)
		head=${GITHUB_SHA:?}
		target_branch=${GITHUB_REF#refs/heads/}
		;;
	esac
	is_sha "$head" || die "the $event event carries no head SHA"
	[[ -n $target_branch ]] || die "the $event event names no target branch"
	target_sha=$(git -C "$src" rev-parse --verify --quiet "refs/remotes/origin/$target_branch^{commit}") ||
		die "the target branch $target_branch was not fetched"
	if [[ $event == merge_group ]]; then
		# The queue built the group commit from the default branch and the pull requests
		# ahead. The App resolves the members from GitHub; these checks keep the commit the
		# run checks tied to the queue's base.
		git -C "$src" cat-file -e "$group_base^{commit}" 2>/dev/null ||
			die "base commit $group_base is not in the fetched history"
		git -C "$src" merge-base --is-ancestor "$group_base" "$head" ||
			die "the merge group $head is not built on the event's base $group_base"
		git -C "$src" merge-base --is-ancestor "$group_base" "$target_sha" ||
			die "the merge group's base $group_base is not in the history of $target_branch"
	fi
	merge_base=$(git -C "$src" merge-base --all "$head" "$target_sha") ||
		die "no merge base between $head and $target_branch ($target_sha)"
	# After criss-cross merges git has several best merge bases; whether the change edits the
	# policy, and the envelope's merge base, need exactly one.
	[[ $merge_base != *$'\n'* ]] ||
		die "$head and $target_branch have more than one merge base ($(tr '\n' ' ' <<<"$merge_base")); merge $target_branch into the branch so one merge base remains, then push"
	checked_out=$(git -C "$src" rev-parse HEAD)
	[[ $checked_out == "$head" ]] || die "the checkout is at $checked_out, not at the checked commit $head"
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

# select_policy decides which policy file the engine judges with (see the header) and,
# for the target's, writes its blob. It returns 1 when there is no policy to check with.
select_policy() {
	local rc=0 entry fmode ftype oid
	git -C "$src" diff --quiet --no-ext-diff "$merge_base" "$head" -- "$POLICY" || rc=$?
	case $rc in
	0) policy_source=target ;;
	1) policy_source=checkout ;;
	*) die "git diff failed for $POLICY" ;;
	esac
	[[ $head != "$target_sha" ]] || policy_source=checkout
	if [[ $policy_source == checkout ]]; then
		[[ -n $(git -C "$src" ls-tree "$head" -- "$POLICY") || -n $(git -C "$src" ls-tree "$target_sha" -- "$POLICY") ]]
		return
	fi
	entry=$(git -C "$src" ls-tree "$target_sha" -- "$POLICY") || die "git ls-tree failed for $POLICY at $target_sha"
	[[ -n $entry ]] || return 1
	read -r fmode ftype oid <<<"${entry%%$'\t'*}"
	[[ $ftype == blob && ($fmode == 100644 || $fmode == 100755) ]] ||
		die "$POLICY at $target_branch ($target_sha) is not a regular file (git mode $fmode)"
	git -C "$src" cat-file blob "$oid" >"$policy_copy" || die "cannot read $POLICY at $target_sha"
}

engine() {
	local mounts=()
	[[ $policy_source != target ]] || mounts+=(--volume "$policy_copy:$POLICY_MOUNT:ro")
	docker run --rm --pull never \
		--user "$(id -u):$(id -g)" \
		--cap-drop ALL --security-opt no-new-privileges \
		--env HOME=/tmp \
		--env GIT_CONFIG_COUNT=1 \
		--env GIT_CONFIG_KEY_0=safe.directory \
		--env GIT_CONFIG_VALUE_0=/src \
		--volume "$src:/src" \
		--volume "$src/.git:/src/.git:ro" \
		${mounts[@]+"${mounts[@]}"} \
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

# check runs `archfit check` once. The exit code is the status: 0 pass, 1 fail, 2 unknown.
# Exit 2 with nothing on stdout is a usage or tool error: no result was produced.
check() {
	local args=(check --format json --base "refs/remotes/origin/$target_branch") rc=0 schema expected
	[[ $policy_source != target ]] || args+=(--policy "$POLICY_MOUNT")
	payload=$out/archfit-result.json
	engine "${args[@]}" >"$payload" 2>"$engine_log" || rc=$?
	case $rc in
	0 | 1 | 2) ;;
	*) engine_failed "the engine container exited $rc" ;;
	esac
	[[ -s $payload ]] || engine_failed "archfit exited $rc without a result: a usage or tool error"
	schema=$(jq -r '.schema // ""' "$payload" 2>/dev/null) || engine_failed "the engine output is not JSON"
	[[ $schema == "$RESULT_SCHEMA" ]] ||
		engine_failed "the engine output declares schema '$schema'; this action carries $RESULT_SCHEMA"
	show_engine_log
	status=$(jq -r '.status // ""' "$payload")
	# waiting is the App's status; the engine never gives it.
	case $status in
	pass) expected=0 ;;
	fail) expected=1 ;;
	unknown) expected=2 ;;
	*) die "the result declares no status the engine gives ('$status')" ;;
	esac
	[[ $rc == "$expected" ]] || die "archfit exited $rc, but its result says $status"
	policy_digest=$(jq -r '.policy.digest // ""' "$payload")
	[[ $policy_digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "the result names no policy digest ('$policy_digest')"
}

write_facts() {
	jq -n \
		--arg event "$event" --arg head_sha "$head" --arg merge_base_sha "$merge_base" \
		--arg target_ref "refs/heads/$target_branch" --arg target_sha "$target_sha" \
		--arg policy_source "$policy_source" --arg policy_digest "$policy_digest" \
		--argjson pull_request "$pull_request" --argjson fork "$fork" \
		--arg engine_version "$engine_version" --arg image_digest "$image_digest" --arg platform "$platform" \
		--arg payload_file "$payload" --arg status "$status" \
		'{event: $event, head_sha: $head_sha, merge_base_sha: $merge_base_sha,
		  target_ref: $target_ref, target_sha: $target_sha,
		  policy_source: $policy_source, policy_digest: $policy_digest,
		  pull_request: $pull_request, fork: $fork,
		  engine_version: $engine_version, image_digest: $image_digest, platform: $platform,
		  payload_file: $payload_file, status: $status}' \
		>"$work/facts.json"
	set_output facts-file "$work/facts.json"
	set_output payload-file "$payload"
	set_output artifact-name archfit-result
	set_output verdict "$status"
}

write_summary() {
	local what="pushed commit \`$head\`" policy
	if [[ $event == pull_request ]]; then
		what="head \`$head\` of pull request #$pull_request"
	elif [[ $event == merge_group ]]; then
		what="merge group commit \`$head\` on base \`$group_base\`"
	fi
	if [[ $policy_source == target ]]; then
		policy="\`$POLICY\` of the target tip, \`sha256:$(sha256_hex "$policy_copy")\`"
	elif [[ $head == "$target_sha" ]]; then
		policy="\`$POLICY\` of the checkout, which is the target tip"
	else
		policy="\`$POLICY\` of the checkout: the change edits it, so the engine compares it with the target's"
	fi
	summary "### archfit check" "" \
		"- Checked: $what" \
		"- Target: \`refs/heads/$target_branch\` at \`$target_sha\`, merge base \`$merge_base\`" \
		"- Policy: $policy" \
		"- Engine: $engine_version, $platform, \`$image_digest\`" \
		"- Status: ${status:-none}" ""
}

resolve_revisions
assert_no_credentials
if ! select_policy; then
	notice "no $POLICY at $target_branch ($target_sha) or in this change; there is no policy to check with. Run archfit init and merge its pull request first."
	write_facts
	exit 0
fi
engine_identity
check
write_facts
write_summary
printf 'archfit: %s %s status=%s result=%s\n' "$event" "$head" "$status" "$payload"
