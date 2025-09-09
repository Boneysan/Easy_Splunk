#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Script directory setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- config flags -------------------------------------------------------------
AUTO_YES="${AUTO_YES:-0}"
AUTO_CONTINUE="${AUTO_CONTINUE:-0}"   # try sg/newgrp to resume in same terminal
PREFER_DOCKER="${PREFER_DOCKER:-1}"   # prefer Docker on Ubuntu/Debian/RHEL-like

# parse args
for a in "$@"; do
  case "$a" in
    --yes|-y) AUTO_YES=1 ;;
    --auto-continue) AUTO_CONTINUE=1 ;;
    --prefer-docker) PREFER_DOCKER=1 ;;
    --prefer-podman) PREFER_DOCKER=0 ;;
    *) ;;
  esac
done

log() { printf '[%s] %s\n' "$1" "$2"; }
confirm() {
  if [[ "$AUTO_YES" == "1" ]]; then return 0; fi
  read -r -p "$1 [y/N]: " r; [[ "$r" =~ ^[Yy] ]] || return 1
}

require_root_or_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      log ERROR "sudo not found and not root"
      exit 1
    fi
  fi
}

as_root() {
  if [[ $EUID -eq 0 ]]; then bash -c "$*"; else sudo bash -c "$*"; fi
}

detect_os() {
  . /etc/os-release
  echo "${ID:-unknown}:${VERSION_ID:-0}"
}

ensure_services() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    as_root "systemctl enable --now $svc" || true
  fi
}

install_docker() {
  local os; os="$(detect_os)"
  case "$os" in
    ubuntu:*|debian:*)
      as_root "apt-get update -y"
      as_root "apt-get install -y ca-certificates curl gnupg"
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
        | as_root "gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
      as_root "chmod a+r /etc/apt/keyrings/docker.gpg"
      . /etc/os-release
      echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
        | as_root "tee /etc/apt/sources.list.d/docker.list >/dev/null"
      as_root "apt-get update -y"
      as_root "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    rhel:*|rocky:*|almalinux:*|centos:*)
      as_root "dnf -y install dnf-plugins-core"
      as_root "dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
      as_root "dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    fedora:*)
      as_root "dnf -y install dnf-plugins-core"
      as_root "dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --allowerasing"
      ;;
    *)
      log ERROR "Unsupported OS for automated Docker install."
      exit 1
      ;;
  esac

  ensure_services docker
}

install_podman() {
  local os; os="$(detect_os)"
  case "$os" in
    ubuntu:*|debian:*) as_root "apt-get update -y && apt-get install -y podman" ;;
    rhel:*|rocky:*|almalinux:*|centos:*|fedora:*) as_root "dnf -y install podman" ;;
    *) log ERROR "Unsupported OS for automated Podman install."; exit 1 ;;
  esac
}

main() {
  require_root_or_sudo
  log INFO "Detected: $(detect_os)"

  if [[ "$PREFER_DOCKER" == "1" ]]; then
    log INFO "Installing Docker (preferred)..."
    install_docker
  else
    log INFO "Installing Podman (preferred)..."
    install_podman
  fi

  local user="${SUDO_USER:-$USER}"
  local need_relogin=0

  if command -v docker >/dev/null 2>&1; then
    # ensure docker group exists
    if ! getent group docker >/dev/null 2>&1; then
      as_root "groupadd docker" || true
    fi
    # add user to docker group if not already
    if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
      log INFO "Adding $user to docker group…"
      as_root "usermod -aG docker $user"
      need_relogin=1
    fi
    ensure_services docker
  fi

  # quick smoke test (may still fail if relogin needed)
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      log OK "Docker daemon reachable."
    else
      log WARN "Docker installed but current shell may lack group membership."
    fi
  fi

  if (( need_relogin )); then
    log WARN "Group membership changed for user '$user'. A new login session is required."
    echo
    echo "➡  Do one of the following:"
    echo "   - **Recommended:** log out and back in, then run:"
    echo "       ./verify-installation.sh && ./deploy.sh small --with-monitoring"
    echo "   - **Or (same terminal, experimental):**"
    echo "       sg docker -c './verify-installation.sh && ./deploy.sh small --with-monitoring'"
    echo
    # Exit with a distinct, documented code for "re-login required"
    if [[ "$AUTO_CONTINUE" == "1" ]] && command -v sg >/dev/null 2>&1; then
      log INFO "Attempting AUTO CONTINUE via 'sg docker'…"
      exec sg docker -c "bash -lc './verify-installation.sh'"
    fi
    exit 78
  fi

  log OK "Phase-1 complete. Proceed with: ./verify-installation.sh"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  source "${SCRIPT_DIR}/lib/run-with-log.sh" || true
  run_entrypoint main "$@"
fi
