#!/bin/bash
# git-csaf-vex-gen-ci.sh — generate CSAF VEX documents from fork git history
#
# Designed for Nordix forks where release tags follow the pattern:
#   v1.7.3-est-1, camel-3.14.10-est-1, kustomize/v1.24.0-est1
#
# The script auto-resolves the upstream base tag from the release tag,
# fetches it from the upstream repo, and uses it as the scan starting point.
#
# Only requires: git, jq, gh, date (coreutils)
#
# Usage: ./git-csaf-vex-gen-ci.sh [repo-path] [product-purl] [OPTIONS]
#   repo-path:       path to the git repo (default: .)
#   product-purl:    PURL for the product (default: auto-detected as pkg:generic/<repo-name>@<latest-tag>)
#
# Options:
#   --release-tag TAG      the fork release tag (e.g. v1.7.3-est-1); auto-computes
#                          base tag by stripping -est[N] suffix and fetches from upstream
#   --since-ref REF        tag/commit to scan from (overrides --release-tag auto-detection)
#   --output-dir DIR       where to write VEX files (default: vex-output)
#   --upstream-url URL     upstream repo URL for fetching base tags (auto-detected if omitted)
#   --per-cve              also emit individual per-CVE CSAF VEX files

set -euo pipefail

# ─── Defaults & constants ───────────────────────────────────────────────────

OUTPUT_DIR="vex-output"
SINCE_REF=""
EST_RELEASE_TAG=""
UPSTREAM_URL=""
REPO_PATH=""
PRODUCT_PURL=""
PER_CVE=false

readonly PUBLISHER_NAME="EST"
readonly PUBLISHER_NS="https://github.com/Nordix"

# ─── Parse arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
    --since-ref)     SINCE_REF="$2"; shift 2 ;;
    --release-tag)   EST_RELEASE_TAG="$2"; shift 2 ;;
    --upstream-url)  UPSTREAM_URL="$2"; shift 2 ;;
    --per-cve)       PER_CVE=true; shift ;;
    -*)              echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [ -z "$REPO_PATH" ]; then
        REPO_PATH="$1"
      elif [ -z "$PRODUCT_PURL" ]; then
        PRODUCT_PURL="$1"
      else
        echo "Unexpected argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done

REPO_PATH="${REPO_PATH:-.}"

# ─── Validate ───────────────────────────────────────────────────────────────

command -v jq >/dev/null 2>&1 || { echo "Error: jq not found in PATH" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found in PATH" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "Error: gh not found in PATH" >&2; exit 1; }

if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: $REPO_PATH is not a git repository" >&2
  exit 1
fi

cd "$REPO_PATH"

# Derive the GitHub org/repo slug from origin (used for gh api calls)
REPO_SLUG=$(git remote get-url origin | sed 's|.*github\.com[:/]||; s|\.git$||')

# ─── Auto-detect release tag if not provided ────────────────────────────────

if [ -z "$EST_RELEASE_TAG" ] && [ -z "$SINCE_REF" ]; then
  # Find the latest -est tag in the repo (exclude api/ prefixed Go module tags).
  # Matches any -est marker regardless of what follows: -est, -est1, -est-1, -est.rc2 ...
  EST_RELEASE_TAG=$(git tag --sort=-creatordate | grep -v '^api/' | grep -E -- '-est' | head -1 || true)
  if [ -n "$EST_RELEASE_TAG" ]; then
    echo "Auto-detected release tag: $EST_RELEASE_TAG"
  else
    # Last resort: scan commits by @est.tech authors
    first_est=$(git log --author="@est.tech" --format="%H" --reverse | head -1)
    if [ -n "$first_est" ]; then
      echo "No -est tag found, scanning from first @est.tech commit"
      SINCE_REF="$first_est"
    else
      echo "Error: No -est tag found, no @est.tech commits, and no --release-tag or --since-ref provided" >&2
      exit 1
    fi
  fi
fi

# ─── Upstream base tag resolution ───────────────────────────────────────────

if [ -n "$EST_RELEASE_TAG" ] && [ -z "$SINCE_REF" ]; then
  # Strip the -est marker and everything after it, whatever form it takes.
  # The leading (.*) anchors on the last -est, so tags whose name part
  # also contains "-est" strip correctly.
  UPSTREAM_BASE_TAG=$(echo "$EST_RELEASE_TAG" | sed -E 's/(.*)-est.*$/\1/')
  echo "EST release tag: $EST_RELEASE_TAG"
  echo "Computed upstream base tag: $UPSTREAM_BASE_TAG"

  # Fetch from upstream if not available locally
  if ! git rev-parse "refs/tags/${UPSTREAM_BASE_TAG}" >/dev/null 2>&1; then
    echo "Base tag $UPSTREAM_BASE_TAG not found locally, attempting to fetch from upstream..."

    if [ -z "$UPSTREAM_URL" ]; then

      if command -v gh >/dev/null 2>&1; then
        UPSTREAM_URL=$(gh api "repos/${REPO_SLUG}" --jq '.parent.clone_url' 2>/dev/null || true)
      fi

      if [ -n "$UPSTREAM_URL" ]; then
        echo "Auto-detected upstream: $UPSTREAM_URL"
      else
        echo "Warning: Could not auto-detect upstream repo URL" >&2
        echo "  Use --upstream-url to specify it manually" >&2
      fi
    fi

    if [ -n "$UPSTREAM_URL" ]; then
      git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
      git fetch upstream "refs/tags/${UPSTREAM_BASE_TAG}:refs/tags/${UPSTREAM_BASE_TAG}" 2>/dev/null \
        && echo "Fetched tag $UPSTREAM_BASE_TAG from upstream" \
        || echo "Warning: Could not fetch tag $UPSTREAM_BASE_TAG from upstream" >&2
    fi
  fi

  if git rev-parse "refs/tags/${UPSTREAM_BASE_TAG}" >/dev/null 2>&1; then
    SINCE_REF="$UPSTREAM_BASE_TAG"
    echo "Using base tag as since-ref: $SINCE_REF"
  else
    echo "Error: Upstream base tag $UPSTREAM_BASE_TAG not available locally or from upstream" >&2
    exit 1
  fi
fi

# ─── Auto-detect PRODUCT_PURL ──────────────────────────────────────────────

if [ -z "$PRODUCT_PURL" ]; then
  PRODUCT_NAME=$(basename "$(git remote get-url origin 2>/dev/null | sed 's|\.git$||')")
  PRODUCT_VERSION="${EST_RELEASE_TAG:-${SINCE_REF}}"
  PRODUCT_PURL="pkg:generic/${PRODUCT_NAME}@${PRODUCT_VERSION}"
  echo "Auto-detected PRODUCT_PURL: $PRODUCT_PURL"
else
  PRODUCT_NAME=$(echo "$PRODUCT_PURL" | sed 's|^pkg:[^/]*/||; s|@.*||; s|?.*||')
  PRODUCT_VERSION=$(echo "$PRODUCT_PURL" | sed 's|^[^@]*@||; s|?.*||')
fi
VENDOR_NAME="$PUBLISHER_NAME"

# ─── Helper: record CVE ────────────────────────────────────────────────────

record_cve() {
  local cve="$1" source="$2" note="$3" remediation="$4"

  if [ -n "${CVE_MAP[$cve]:-}" ]; then
    return 0
  fi

  CVE_MAP[$cve]="$source"
  jq -n --compact-output \
    --arg cve "$cve" \
    --arg commit "$source" \
    --arg note "$note" \
    --arg remediation "$remediation" \
    '{
      cve: $cve,
      commit: $commit,
      notes: [{category: "description", text: $note}],
      product_status: {fixed: ["CSAFPID-0001"]},
      remediations: [{category: "vendor_fix", details: $remediation, product_ids: ["CSAFPID-0001"]}]
    }' >> "$CVE_ENTRIES_FILE"
  echo "   $cve ($source)"
}

# ─── Determine commit range and extract CVE-to-commit mapping ──────────────

LOG_RANGE="${SINCE_REF}^..HEAD"

echo "Scanning commits since ${SINCE_REF:-first EST commit}"

# Single-pass: extract all CVE mentions with their commit hash and message
# Output: one JSON object per CVE (earliest commit wins due to --reverse)
declare -A CVE_MAP=()
CVE_ENTRIES_FILE=$(mktemp)
trap 'rm -f "$CVE_ENTRIES_FILE"' EXIT

while IFS= read -r -d '' line; do
  # git log emits "\0\n" between records, so every record after the first
  # arrives with a leading newline. Strip leading whitespace before parsing.
  line="${line#"${line%%[![:space:]]*}"}"
  [ -n "$line" ] || continue
  commit_hash="${line%% *}"
  rest="${line#* }"
  cve_matches=$(echo "$rest" | grep -oE 'CVE-[0-9]{4}-[0-9]{4,}' || true)
  for cve in $cve_matches; do
    commit_msg=$(echo "$rest" | head -1)
    record_cve "$cve" "${commit_hash:0:12}" \
      "Fixed via commit ${commit_hash:0:12}: ${commit_msg}" \
      "Update to ${PRODUCT_NAME} ${PRODUCT_VERSION} or later (fork commit ${commit_hash:0:12})"
  done
done < <(git log "$LOG_RANGE" --reverse --format="%H %s %b%x00")

# ─── Scan pull requests for CVEs ───────────────────────────────────────────

echo "Scanning merged pull requests between ${SINCE_REF} and HEAD..."

# Set of commits in range, used to decide whether a PR landed in this release.
declare -A RANGE_SHAS=()
while IFS= read -r sha; do
  [ -n "$sha" ] && RANGE_SHAS["$sha"]=1
done < <(git rev-list "$LOG_RANGE" 2>/dev/null || true)

if [ "${#RANGE_SHAS[@]}" -gt 0 ]; then
  # Only merged PRs: an open or closed-unmerged PR still exposes a
  # merge_commit_sha, and treating one as "fixed" would be a false VEX claim.
  while IFS=$'\t' read -r pr_num pr_sha pr_title pr_text; do
    [ -n "${pr_num:-}" ] || continue
    # Skip PRs whose merge commit is not part of this release range
    [ -n "${RANGE_SHAS[${pr_sha:-}]:-}" ] || continue

    pr_cves=$(echo "$pr_text" | grep -oE 'CVE-[0-9]{4}-[0-9]{4,}' || true)
    for cve in $pr_cves; do
      record_cve "$cve" "pr:${pr_num}" \
        "Fixed via PR #${pr_num} (commit ${pr_sha:0:12}): ${pr_title}" \
        "Update to ${PRODUCT_NAME} ${PRODUCT_VERSION} or later (fork PR #${pr_num}, commit ${pr_sha:0:12})"
    done
  done < <(gh api --paginate "repos/${REPO_SLUG}/pulls?state=closed&per_page=100" \
    --jq '.[]
          | select(.merged_at != null)
          | [ (.number|tostring),
              (.merge_commit_sha // ""),
              (.title | gsub("[\n\r\t]"; " ")),
              ((.title + " " + (.body // "")) | gsub("[\n\r\t]"; " ")) ]
          | @tsv' 2>/dev/null || true)
fi

# ─── Scan release descriptions for CVEs ────────────────────────────────────

echo "Scanning release descriptions between ${SINCE_REF} and HEAD..."

# Get all tags reachable from HEAD but not from SINCE_REF (i.e., tags in our range)
TAGS_IN_RANGE=$(git tag --merged HEAD --no-merged "$SINCE_REF" 2>/dev/null || true)

if [ -n "$TAGS_IN_RANGE" ]; then
  while IFS= read -r tag; do
    release_body=$(gh api "repos/${REPO_SLUG}/releases/tags/${tag}" --jq '.body // empty' 2>/dev/null || true)
    if [ -z "$release_body" ]; then
      continue
    fi

    release_cves=$(echo "$release_body" | grep -oE 'CVE-[0-9]{4}-[0-9]{4,}' || true)
    for cve in $release_cves; do
      record_cve "$cve" "release:$tag" \
        "Referenced in release ${tag}" \
        "Update to ${PRODUCT_NAME} ${PRODUCT_VERSION} or later (see release ${tag})"
    done
  done <<< "$TAGS_IN_RANGE"
fi

cve_count="${#CVE_MAP[@]}"

if [ "$cve_count" -eq 0 ]; then
  echo "No CVE references found in git history"
  exit 1
fi

echo "Found $cve_count CVEs"

# ─── Timestamps & IDs ──────────────────────────────────────────────────────

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TODAY=$(date -u +"%Y-%m-%d")
TRACKING_ID="nordix-${PRODUCT_NAME}-vex-${TODAY}"

# ─── Helper: build CSAF VEX document wrapper ───────────────────────────────

build_csaf_doc() {
  local title="$1"
  local tracking_id="$2"
  local vulns_json="$3"

  jq -n \
    --arg title "$title" \
    --arg tracking_id "$tracking_id" \
    --arg now "$NOW_ISO" \
    --arg pub_name "$PUBLISHER_NAME" \
    --arg pub_ns "$PUBLISHER_NS" \
    --arg vendor "$VENDOR_NAME" \
    --arg prod_name "$PRODUCT_NAME" \
    --arg prod_version "$PRODUCT_VERSION" \
    --arg prod_fullname "${VENDOR_NAME} ${PRODUCT_NAME} ${PRODUCT_VERSION}" \
    --arg purl "$PRODUCT_PURL" \
    --argjson vulns "$vulns_json" \
    '{
      document: {
        category: "csaf_vex",
        csaf_version: "2.0",
        title: $title,
        publisher: {
          category: "vendor",
          name: $pub_name,
          namespace: $pub_ns
        },
        tracking: {
          id: $tracking_id,
          initial_release_date: $now,
          current_release_date: $now,
          status: "final",
          version: "1",
          revision_history: [{date: $now, number: "1", summary: "Initial VEX statement"}]
        },
        distribution: {tlp: {label: "WHITE"}}
      },
      product_tree: {
        branches: [{
          category: "vendor",
          name: $vendor,
          branches: [{
            category: "product_name",
            name: $prod_name,
            branches: [{
              category: "product_version",
              name: $prod_version,
              product: {
                name: $prod_fullname,
                product_id: "CSAFPID-0001",
                product_identification_helper: {purl: $purl}
              }
            }]
          }]
        }]
      },
      vulnerabilities: $vulns
    }'
}

# ─── Generate output ───────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

# Build combined vulnerabilities array from newline-delimited JSON (single jq call)
VULNS_JSON=$(jq -s '[.[] | del(.commit)]' "$CVE_ENTRIES_FILE")

COMBINED_FILE="$OUTPUT_DIR/combined.csaf.json"
build_csaf_doc \
  "VEX for ${PRODUCT_NAME} ${PRODUCT_VERSION} (Nordix fork)" \
  "$TRACKING_ID" \
  "$VULNS_JSON" > "$COMBINED_FILE"

if [ "$PER_CVE" = true ]; then
  while IFS= read -r entry; do
    cve=$(echo "$entry" | jq -r '.cve')
    vuln_json=$(echo "$entry" | jq '[del(.commit)]')
    build_csaf_doc \
      "VEX: ${cve} fixed in ${PRODUCT_NAME} (Nordix fork)" \
      "nordix-${PRODUCT_NAME}-${cve}-${TODAY}" \
      "$vuln_json" > "$OUTPUT_DIR/${cve}.csaf.json"
  done < "$CVE_ENTRIES_FILE"
fi

# ─── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "Combined CSAF VEX: $COMBINED_FILE"
echo "  Vulnerabilities: $cve_count"
echo "  Product: $PRODUCT_PURL"
echo "  Tracking ID: $TRACKING_ID"

if [ "$PER_CVE" = true ]; then
  per_cve_count=$(find "$OUTPUT_DIR" -name "CVE-*.csaf.json" | wc -l)
  echo "  Per-CVE files: $per_cve_count"
fi
