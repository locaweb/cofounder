#!/usr/bin/env bash
#
# Host orchestrator for the install.sh container suite (Step 1 of the test plan,
# see ideas/test-plan.md). Builds a clean Ubuntu image and runs the local
# working-tree install.sh through the A0/A1 scenarios inside it. Non-destructive
# to the host — everything happens in an ephemeral container.
#
# Usage:   tests/install/test-install.sh
# Engine:  ENGINE=docker tests/install/test-install.sh   (defaults to podman)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-cofounder-test:ubuntu}"

echo "==> Building $IMAGE"
"$ENGINE" build -t "$IMAGE" -f "$HERE/Dockerfile.ubuntu" "$HERE"

echo "==> Running install.sh suite in a clean container"
"$ENGINE" run --rm \
  -v "$REPO/tests:/work/tests:ro" \
  -v "$REPO/skills/cofounder-computer-setup/scripts:/work/scripts:ro" \
  -e INSTALL_SH=/work/scripts/install.sh \
  -e ASSERT=/work/tests/lib/assert.sh \
  "$IMAGE" \
  bash /work/tests/install/run-in-container.sh
