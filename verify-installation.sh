#!/usr/bin/env bash
set -euo pipefail

fail() { printf '[FAIL] %s\n' "$1"; exit 1; }
ok()   { printf '[ OK ] %s\n' "$1"; }

# 1) docker or podman present?
if command -v docker >/dev/null 2>&1; then
  RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
  RUNTIME="podman"
else
  fail "Neither Docker nor Podman found. Run ./install-prerequisites.sh"
fi
ok "Container runtime detected: $RUNTIME"

# 2) daemon reachable (docker) / socket usable (podman)
if [[ "$RUNTIME" == "docker" ]]; then
  if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon not reachable by current user. If you just added the docker group, log out/in."
  fi
  ok "Docker daemon reachable"
  # 3) compose available
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose available"
  else
    fail "docker compose plugin not found. Re-run ./install-prerequisites.sh"
  fi
else
  if ! podman info >/dev/null 2>&1; then
    fail "Podman not functional. Re-run ./install-prerequisites.sh"
  fi
  ok "Podman usable"
  if podman compose version >/dev/null 2>&1 || command -v podman-compose >/dev/null 2>&1; then
    ok "podman compose available"
  else
    fail "podman compose not found. Re-run ./install-prerequisites.sh --prefer-podman"
  fi
fi

printf '\nAll checks passed. You can deploy now.\n'
