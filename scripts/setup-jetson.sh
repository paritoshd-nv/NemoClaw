#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Jetson host setup for NemoClaw.
#
# Usage:
#   bash scripts/setup-jetson.sh              # detect family and configure
#   bash scripts/setup-jetson.sh --detect     # print detected family (thor|orin) and exit
#   bash scripts/setup-jetson.sh orin         # configure for a specific family
#
# Root operations are performed with inline sudo — the invoking user will be
# prompted for their password if needed. Do NOT run this script with sudo.

set -euo pipefail

C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_RESET='\033[0m'

info() { printf "${C_GREEN}[INFO]${C_RESET}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
ok() { printf "  ${C_GREEN}✓${C_RESET}  %s\n" "$*"; }
error() {
  printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

detect_jetson() {
  local gpu_name
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  local normalized="${gpu_name,,}"

  if [[ "$normalized" == *thor* ]]; then
    printf "%s" "thor"
  elif [[ "$normalized" == *orin* ]]; then
    printf "%s" "orin"
  fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

configure_jetson_host() {
  local family="$1"

  info "Jetson ${family} detected — applying required host configuration"
  info "Sudo is required for kernel and Docker configuration — you may be prompted for your password."

  case "$family" in
    orin)
      sudo update-alternatives --set iptables /usr/sbin/iptables-legacy

      if [[ -f /etc/docker/daemon.json ]]; then
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        sudo python3 -c "
import json, os, tempfile
path = '/etc/docker/daemon.json'
with open(path) as f:
    cfg = json.load(f)
cfg.pop('iptables', None)
cfg.pop('bridge', None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w') as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, path)
"
      else
        warn "/etc/docker/daemon.json not found — skipping Docker daemon patch"
      fi
      ;;
    thor) ;; # No daemon.json or iptables changes needed on Thor
    *)
      error "Unsupported Jetson family: $family"
      ;;
  esac

  # Load br_netfilter now and persist it across reboots.
  sudo modprobe br_netfilter
  echo "br_netfilter" | sudo tee /etc/modules-load.d/nemoclaw.conf >/dev/null

  # Enable iptables processing for bridged traffic (required by k3s).
  # Persist via sysctl.d so the setting survives reboots.
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
  sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null
  printf 'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\n' \
    | sudo tee /etc/sysctl.d/99-nemoclaw.conf >/dev/null

  if [[ "$family" == "orin" ]]; then
    if sudo systemctl list-unit-files docker.service >/dev/null 2>&1; then
      sudo systemctl restart docker
    else
      warn "Docker service not found — skipping restart"
    fi
  fi

  ok "Jetson ${family} host configuration applied"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  if [[ "${1:-}" == "--detect" ]]; then
    detect_jetson
    exit 0
  fi

  local family="${1:-$(detect_jetson)}"
  if [[ -z "$family" ]]; then
    exit 0
  fi

  configure_jetson_host "$family"
}

main "$@"
