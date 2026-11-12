#!/bin/sh
# A cut's publish (docs/agents/afkconvoy.md, ADR-0017): pushes the tag TAG
# (a no-op when the cut's tag step already did) and waits for the release
# workflow's run on that tag's commit, failing when the run fails. The run
# builds, signs, notarizes, verifies and publishes the Release; this host only
# watches it.
#
# RELEASE_REMOTE (default origin) is where the tag goes. The run is looked for
# every RELEASE_WAIT_POLL seconds (default 10), RELEASE_WAIT_TRIES times
# (default 60), since Actions starts it a little after the push.
# tools/release-wait-test.sh checks it with gh faked.
set -eu
tag=${1:?usage: tools/release-wait.sh TAG}
remote=${RELEASE_REMOTE:-origin}
poll=${RELEASE_WAIT_POLL:-10}
tries=${RELEASE_WAIT_TRIES:-60}
workflow=release.yml

sha=$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}") \
	|| { echo "release-wait: no tag $tag here" >&2; exit 1; }
git push --quiet "$remote" "refs/tags/$tag"

n=0
while :; do
	id=$(gh run list --workflow "$workflow" --commit "$sha" --event push \
		--json databaseId --jq '.[0].databaseId // empty')
	[ -z "$id" ] || break
	n=$((n + 1))
	[ "$n" -lt "$tries" ] || {
		echo "release-wait: no $workflow run on $tag ($sha) after $((tries * poll)) s" >&2
		exit 1
	}
	sleep "$poll"
done

echo "release-wait: watching $workflow run $id on $tag"
gh run watch "$id" --exit-status --interval 30 >/dev/null || {
	echo "release-wait: the $workflow run $id on $tag failed: gh run view $id --log-failed" >&2
	exit 1
}
echo "release-wait: $tag is released"
