#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAPERCLIPAI_VERSION="${PAPERCLIPAI_VERSION:-latest}"
HOST_PORT="${HOST_PORT:-3232}"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/data/release-smoke-$PAPERCLIPAI_VERSION}"
SMOKE_ARTIFACT_DIR="${SMOKE_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/paperclip-release-smoke.XXXXXX")}"
SMOKE_METADATA_FILE="${SMOKE_METADATA_FILE:-$SMOKE_ARTIFACT_DIR/release-smoke.env}"
IMAGE_NAME="${IMAGE_NAME:-paperclip-release-smoke-$PAPERCLIPAI_VERSION-$HOST_PORT}"
RELEASE_SMOKE_KEEP_CONTAINER="${RELEASE_SMOKE_KEEP_CONTAINER:-false}"
SMOKE_CONTAINER_NAME=""

require_command() {
  local command_name="$1"
  local install_hint="$2"
  if command -v "$command_name" >/dev/null 2>&1; then
    return 0
  fi
  echo "Release smoke cannot start: required command '$command_name' is not available." >&2
  echo "Install hint: $install_hint" >&2
  echo "CI fallback: gh workflow run release-smoke.yml -f paperclip_version=$PAPERCLIPAI_VERSION" >&2
  exit 1
}

cleanup() {
  if [[ "$RELEASE_SMOKE_KEEP_CONTAINER" == "true" ]]; then
    return 0
  fi
  if [[ -n "$SMOKE_CONTAINER_NAME" ]]; then
    docker rm -f "$SMOKE_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

require_command docker "Install Docker Desktop or another Docker runtime with the 'docker' CLI on PATH."
require_command pnpm "Install pnpm 9.x and rerun from the repo root."

mkdir -p "$SMOKE_ARTIFACT_DIR"

echo "==> Launching release smoke harness"
HOST_PORT="$HOST_PORT" \
DATA_DIR="$DATA_DIR" \
PAPERCLIPAI_VERSION="$PAPERCLIPAI_VERSION" \
IMAGE_NAME="$IMAGE_NAME" \
SMOKE_DETACH=true \
SMOKE_METADATA_FILE="$SMOKE_METADATA_FILE" \
"$REPO_ROOT/scripts/docker-onboard-smoke.sh"

set -a
# shellcheck disable=SC1090
source "$SMOKE_METADATA_FILE"
set +a

SMOKE_CONTAINER_NAME="${SMOKE_CONTAINER_NAME:-}"
if [[ -z "$SMOKE_CONTAINER_NAME" ]]; then
  echo "Release smoke failed: harness metadata did not include SMOKE_CONTAINER_NAME" >&2
  exit 1
fi

echo "==> Running release smoke Playwright suite"
set +e
PAPERCLIP_RELEASE_SMOKE_BASE_URL="$SMOKE_BASE_URL" \
  PAPERCLIP_RELEASE_SMOKE_EMAIL="$SMOKE_ADMIN_EMAIL" \
  PAPERCLIP_RELEASE_SMOKE_PASSWORD="$SMOKE_ADMIN_PASSWORD" \
  pnpm run test:release-smoke
test_status=$?
set -e

echo "==> Capturing release smoke diagnostics"
docker logs "$SMOKE_CONTAINER_NAME" >"$SMOKE_ARTIFACT_DIR/docker-onboard-smoke.log" 2>&1 || true

if [[ $test_status -ne 0 ]]; then
  echo "Release smoke failed: Playwright exited with status $test_status" >&2
  echo "    Harness metadata: $SMOKE_METADATA_FILE" >&2
  echo "    Docker log: $SMOKE_ARTIFACT_DIR/docker-onboard-smoke.log" >&2
  exit "$test_status"
fi

echo "==> Release smoke passed"
echo "    Paperclip version: $PAPERCLIPAI_VERSION"
echo "    Smoke base URL: $SMOKE_BASE_URL"
echo "    Harness metadata: $SMOKE_METADATA_FILE"
echo "    Docker log: $SMOKE_ARTIFACT_DIR/docker-onboard-smoke.log"
echo "    Playwright report: $REPO_ROOT/tests/release-smoke/playwright-report/index.html"
echo "    Playwright results: $REPO_ROOT/tests/release-smoke/test-results"

if [[ "$RELEASE_SMOKE_KEEP_CONTAINER" == "true" ]]; then
  echo "    Container left running: $SMOKE_CONTAINER_NAME"
fi
