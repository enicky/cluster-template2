#!/usr/bin/env bash
set -Eeuo pipefail

cluster_repo="$(git -C "$(dirname -- "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
toolplanner_candidate="${TOOLPLANNER_REPO:-$cluster_repo/../../../ToolPlanner}"
toolplanner_repo="$(git -C "$toolplanner_candidate" rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'Error: set TOOLPLANNER_REPO to the Tool Planner checkout path.\n' >&2
  exit 1
}

toolplanner_github_repo="enicky/toolplanner"
cluster_github_repo="enicky/cluster-template2"
bootstrap_file="$cluster_repo/bootstrap-apps.yaml"
metadata_artifact="tool-planner-release-metadata"
metadata_dir=""
release_log=""

usage() {
  cat <<'EOF'
Usage:
  scripts/release-tool-planner.sh patch|minor|major
  scripts/release-tool-planner.sh deploy vMAJOR.MINOR.PATCH

Release mode tags the current Tool Planner main and waits for its image build.
Deploy mode resumes from an already-published release tag.
Both modes update local bootstrap configuration, run task configure, and open
a cluster-template PR. Neither mode merges the PR or deploys directly.

Set TOOLPLANNER_REPO if the Tool Planner checkout is not at ../../../ToolPlanner.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$release_log" && -f "$release_log" ]]; then
    rm -f -- "$release_log"
  fi
  if [[ -n "$metadata_dir" && -d "$metadata_dir" ]]; then
    rm -r -- "$metadata_dir"
  fi
}
trap cleanup EXIT

[[ "$#" -gt 0 ]] || { usage >&2; exit 2; }
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
fi

mode=""
bump=""
release_tag=""
case "$1" in
  patch|minor|major)
    [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }
    mode=release
    bump="$1"
    ;;
  deploy)
    [[ "$#" -eq 2 ]] || { usage >&2; exit 2; }
    mode=deploy
    release_tag="$2"
    [[ "$release_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
      die "release tags must match vMAJOR.MINOR.PATCH"
    }
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

for command in git gh jq yq task; do
  command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
gh auth status --hostname github.com >/dev/null 2>&1 || die "authenticate gh with GitHub first"
[[ -f "$bootstrap_file" ]] || die "missing local bootstrap-apps.yaml at $bootstrap_file"
grep -Fq 'fullnameOverride: tool-planner' \
  "$cluster_repo/templates/config/kubernetes/apps/home/tool-planner/values.yaml.j2" \
  || die "the Tool Planner values template must set fullnameOverride: tool-planner"
grep -Fq 'name: tool-planner-release-metadata' \
  "$toolplanner_repo/.github/workflows/ci.yml" \
  || die "the Tool Planner main branch must include the release metadata artifact workflow change"
yq -e '.bootstrap_apps.tool_planner.chart_version' "$bootstrap_file" >/dev/null \
  || die "bootstrap-apps.yaml is missing bootstrap_apps.tool_planner"

ensure_clean_main() {
  local repo="$1"
  local label="$2"
  local branch changes head upstream

  branch="$(git -C "$repo" branch --show-current)"
  [[ "$branch" == main ]] || die "$label must be checked out on main (currently $branch)"
  changes="$(git -C "$repo" status --porcelain --untracked-files=all)"
  [[ -z "$changes" ]] || die "$label has uncommitted changes; clean it before releasing"
  git -C "$repo" fetch origin main --tags
  head="$(git -C "$repo" rev-parse HEAD)"
  upstream="$(git -C "$repo" rev-parse origin/main)"
  [[ "$head" == "$upstream" ]] || die "$label main is not up to date with origin/main"
}

ensure_clean_main "$cluster_repo" "cluster-template"
if [[ "$mode" == release ]]; then
  ensure_clean_main "$toolplanner_repo" "Tool Planner"
fi

if [[ "$mode" == release ]]; then
  release_log="$(mktemp)"
  set +e
  "$toolplanner_repo/scripts/release-images.sh" "$bump" 2>&1 | tee "$release_log"
  release_status="${PIPESTATUS[0]}"
  set -e
  [[ "$release_status" -eq 0 ]] || die "the Tool Planner release script failed"
  release_tag="$(sed -n 's/^Release tag:[[:space:]]*//p' "$release_log" | tail -n 1)"
  [[ "$release_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "no release tag was found; the release may have been cancelled"
fi

git -C "$toolplanner_repo" fetch origin --tags
git -C "$toolplanner_repo" ls-remote --exit-code origin "refs/tags/$release_tag" >/dev/null \
  || die "$release_tag is not published on the Tool Planner origin"
release_commit="$(git -C "$toolplanner_repo" rev-parse "${release_tag}^{commit}")"

printf 'Waiting for the GitHub Actions run for %s (%s)...\n' "$release_tag" "$release_commit"
run_id=""
for ((elapsed = 0; elapsed < 1800; elapsed += 10)); do
  runs="$(gh run list \
    --repo "$toolplanner_github_repo" \
    --workflow ci.yml \
    --branch "$release_tag" \
    --json databaseId,headSha,event,createdAt \
    --limit 20)"
  run_id="$(jq -r --arg sha "$release_commit" \
    '[.[] | select(.headSha == $sha and .event == "push")] | sort_by(.createdAt) | last | .databaseId // empty' \
    <<< "$runs")"
  [[ -n "$run_id" ]] && break
  sleep 10
done
[[ -n "$run_id" ]] || die "no release workflow run appeared within 30 minutes"
gh run watch "$run_id" --repo "$toolplanner_github_repo" --exit-status

metadata_dir="$(mktemp -d)"
gh run download "$run_id" \
  --repo "$toolplanner_github_repo" \
  --name "$metadata_artifact" \
  --dir "$metadata_dir"
metadata_file="$metadata_dir/release-metadata.json"
[[ -f "$metadata_file" ]] || die "release metadata artifact is missing release-metadata.json"
jq -e \
  --arg version "$release_tag" \
  --arg commit "$release_commit" \
  --arg api_image "ghcr.io/enicky/toolplanner-api" \
  --arg web_image "ghcr.io/enicky/toolplanner-web" \
  '.version == $version and .commit == $commit
   and .api.image == $api_image and (.api.digest | test("^sha256:[a-f0-9]{64}$"))
   and .web.image == $web_image and (.web.digest | test("^sha256:[a-f0-9]{64}$"))' \
  "$metadata_file" >/dev/null || die "release metadata did not match the requested tag and images"
api_digest="$(jq -r '.api.digest' "$metadata_file")"
web_digest="$(jq -r '.web.digest' "$metadata_file")"

ensure_clean_main "$cluster_repo" "cluster-template"
cluster_branch="deploy/tool-planner-$release_tag"
if git -C "$cluster_repo" show-ref --verify --quiet "refs/heads/$cluster_branch" \
  || git -C "$cluster_repo" ls-remote --exit-code --heads origin "$cluster_branch" >/dev/null 2>&1; then
  die "cluster branch $cluster_branch already exists"
fi
git -C "$cluster_repo" switch -c "$cluster_branch"

TOOL_PLANNER_RELEASE_VERSION="$release_tag" \
TOOL_PLANNER_API_DIGEST="$api_digest" \
TOOL_PLANNER_WEB_DIGEST="$web_digest" \
  yq -i '
    .bootstrap_apps.tool_planner.chart_version = strenv(TOOL_PLANNER_RELEASE_VERSION) |
    .bootstrap_apps.tool_planner.api_digest = strenv(TOOL_PLANNER_API_DIGEST) |
    .bootstrap_apps.tool_planner.web_digest = strenv(TOOL_PLANNER_WEB_DIGEST)
  ' "$bootstrap_file"

(
  cd "$cluster_repo"
  task configure -y
)

application_file="$cluster_repo/kubernetes/argo/apps/home/tool-planner.yaml"
values_file="$cluster_repo/kubernetes/apps/home/tool-planner/values.yaml"
grep -Fq "targetRevision: \"$release_tag\"" "$application_file" \
  || die "generated Argo Application does not target $release_tag"
grep -Fq "digest: \"$api_digest\"" "$values_file" \
  || die "generated API values do not contain the published digest"
grep -Fq "digest: \"$web_digest\"" "$values_file" \
  || die "generated web values do not contain the published digest"
grep -Fq 'fullnameOverride: tool-planner' "$values_file" \
  || die "generated values lost fullnameOverride: tool-planner"

git -C "$cluster_repo" add -- \
  kubernetes/argo/apps/home/tool-planner.yaml \
  kubernetes/apps/home/tool-planner/values.yaml
git -C "$cluster_repo" diff --cached --check
git -C "$cluster_repo" --no-pager diff --cached --stat
git -C "$cluster_repo" commit -m "chore: deploy Tool Planner $release_tag"
git -C "$cluster_repo" push -u origin "$cluster_branch"

pr_url="$(gh pr create \
  --repo "$cluster_github_repo" \
  --base main \
  --head "$cluster_branch" \
  --title "Deploy Tool Planner $release_tag" \
  --body "Deploy Tool Planner $release_tag with digest-pinned images.

API: ghcr.io/enicky/toolplanner-api@$api_digest
Web: ghcr.io/enicky/toolplanner-web@$web_digest

This PR was prepared by scripts/release-tool-planner.sh. Review and merge to let Argo CD sync the release.")"
printf 'Created cluster deployment PR: %s\n' "$pr_url"
printf 'Review and merge the PR to deploy; this script does not merge or deploy directly.\n'

remaining_changes="$(git -C "$cluster_repo" status --porcelain --untracked-files=all)"
if [[ -n "$remaining_changes" ]]; then
  printf 'Note: task configure changed additional files; only the Tool Planner app and values were staged.\n'
  git -C "$cluster_repo" status --short
fi
