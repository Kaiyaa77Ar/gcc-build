#!/usr/bin/env bash
# Fetch PGO profiles from GitHub Actions CI and build optimized GCC locally.
# Usage: ./fetch-pgo-and-build.sh [arch]
#   arch: arm32|arm64 (default: arm32)
#
# Prerequisites:
#   - GitHub token with repo access (set GITHUB_TOKEN env var)
#   - CI workflow "PGO Pipeline (Instrument + Train)" must have completed
#     for the desired arch.
set -e

ARCH="${1:-arm32}"
REPO="${GITHUB_REPO:-Kaiyaa77Ar/gcc-build}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env var is required}"
API="https://api.github.com/repos/${REPO}"

# Map user-facing arch names to workflow input values
case "$ARCH" in
  arm32)  WORKFLOW_ARCH="arm32" ;;
  arm64)  WORKFLOW_ARCH="arm64" ;;
  *)      echo "Unknown arch: $ARCH (use arm32 or arm64)"; exit 1 ;;
esac

echo "=========================================="
echo " PGO Fetch + Local Optimize Build: $ARCH"
echo "=========================================="

# 1. Find the latest completed workflow run
echo "Fetching latest PGO CI run for ${WORKFLOW_ARCH}..."
RUNS=$(curl -s -H "Authorization: token ${TOKEN}" \
  "${API}/actions/workflows/pgo-ci.yml/runs?status=success&per_page=5")

LATEST_ID=$(echo "$RUNS" | jq -r '.workflow_runs[0].id // empty')
LATEST_URL=$(echo "$RUNS" | jq -r '.workflow_runs[0].html_url // empty')

if [ -z "$LATEST_ID" ]; then
  echo "ERROR: No completed PGO CI run found."
  echo "Run the workflow manually: https://github.com/${REPO}/actions/workflows/pgo-ci.yml"
  echo "Or set GITHUB_REPO if your fork has a different name."
  exit 1
fi

echo "Latest run: ${LATEST_URL} (ID: ${LATEST_ID})"

# 2. Download PGO profiles artifact
echo "Downloading PGO profiles artifact..."
mkdir -p "pgo-profiles-${ARCH}"
if ! curl -s -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/actions/runs/${LATEST_ID}/artifacts" \
  | jq -r '.artifacts[] | select(.name == "pgo-profiles-${WORKFLOW_ARCH}").url' \
  | while read -r url; do
      curl -s -H "Authorization: token ${TOKEN}" -L "$url" -o "pgo-profiles-${WORKFLOW_ARCH}.zip"
    done; then
  echo "WARN: Could not download artifact via API. Trying fallback..."
fi

if [ -f "pgo-profiles-${WORKFLOW_ARCH}.zip" ]; then
  echo "Extracting PGO profiles..."
  unzip -o "pgo-profiles-${WORKFLOW_ARCH}.zip" -d "pgo-profiles-${ARCH}/"
  rm -f "pgo-profiles-${WORKFLOW_ARCH}.zip"
  echo "PGO profiles extracted to pgo-profiles-${ARCH}/"
else
  echo "ERROR: PGO profiles artifact not found or download failed."
  echo "You can manually download from: ${LATEST_URL}"
  exit 1
fi

# 3. Count profile files
PROFILE_COUNT=$(find "pgo-profiles-${ARCH}" -name '*.gcda' -type f | wc -l)
echo "Found ${PROFILE_COUNT} .gcda profile files"
[ "$PROFILE_COUNT" -gt 0 ] || { echo "ERROR: No .gcda files in PGO profiles"; exit 1; }

# 4. Run local optimize build
echo ""
echo "Starting local optimize build with PGO + LTO..."
echo "This may take a while (1-3 hours depending on cores)..."
./build-gcc.sh -a "$ARCH" -p optimize

echo ""
echo "=========================================="
echo " PGO Optimize Build Complete!"
echo " Toolchain: gcc-${ARCH}/bin/"
echo "=========================================="
