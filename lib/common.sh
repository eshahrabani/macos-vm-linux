#!/usr/bin/env bash
# Common helpers: config, logging, prereq checks, asset downloads.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT/data}"
CONF="$ROOT/macos-vm.conf"
[ -f "$CONF" ] && source "$CONF"

# --- defaults ---
VCPU="${VCPU:-8}"
RAM="${RAM:-12G}"
DISK_SIZE_G="${DISK_SIZE_G:-80}"
CPU_MODEL="${CPU_MODEL:-Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check}"
VM_DISPLAY="${VM_DISPLAY:-gtk}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-mac}"
MAC="${MAC:-52:54:00:c9:18:27}"
MAX_MACOS="${MAX_MACOS:-26}"
OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"

# Pinned reference versions (see docs/research.md)
OSXKVM_COMMIT="4c378a4b5e0b219783683012bec680325eb40719"
ASSETS_BASE="https://raw.githubusercontent.com/kholia/OSX-KVM/$OSXKVM_COMMIT"

# paths
DISK="$DATA_DIR/disk.qcow2"
OPEN_CORE="$DATA_DIR/OpenCore.qcow2"
OVMF_CODE="$DATA_DIR/OVMF_CODE_4M.fd"
OVMF_VARS="$DATA_DIR/OVMF_VARS-1920x1080.fd"
BASE_SYSTEM_IMG="$DATA_DIR/BaseSystem.img"
INSTALL_ESD_IMG="$DATA_DIR/InstallESD.img"
PKG="$DATA_DIR/InstallAssistant.pkg"
PKG_DIR="$DATA_DIR/installer-pkg"
ESD_DIR="$DATA_DIR/esd"
SHARED_SUPPORT="$DATA_DIR/SharedSupport.dmg"
RECOVERY_DMG="$DATA_DIR/Recovery.dmg"
RECOVERY_CNK="$DATA_DIR/Recovery.chunklist"
RECOVERY_BOARD_ID="${RECOVERY_BOARD_ID:-Mac-CFF7D910A743CAAF}"
VERSION_FILE="$DATA_DIR/version.txt"
PID_FILE="$DATA_DIR/qemu.pid"
MONITOR_SOCK="$DATA_DIR/monitor.sock"
QEMU_LOG="$DATA_DIR/qemu.log"

log()  { printf '\033[1;36m[macos-vm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[macos-vm] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[macos-vm] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — install it ($2)"; }

prereq_check() {
  require qemu-system-x86_64 "apt install qemu-system"
  require 7z "apt install 7zip"
  require dmg2img "apt install dmg2img"
  require curl "apt install curl"
  require python3
  [ -e /dev/kvm ] || die "/dev/kvm not found — KVM is required"
  [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm not writable — add yourself to the kvm group"
  local free_mb free_gb
  free_mb=$(df -Pk "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4/1024/1024}')
  free_gb=${free_mb%.*}
  [ "$free_gb" -ge "$((DISK_SIZE_G + 40))" ] || die "need ~$((DISK_SIZE_G + 40))G free in $DATA_DIR (have ${free_gb}G) — installer + OS need headroom"
}

# idempotent: 1 > /sys/module/kvm/parameters/ignore_msrs (required by macOS)
ensure_ignore_msrs() {
  [ -w /sys/module/kvm/parameters/ignore_msrs ] && {
    echo 1 > /sys/module/kvm/parameters/ignore_msrs
    return
  }
  warn "kvm ignore_msrs is not set (macOS may crash). Fix with:"
  warn "  echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs"
  warn "macos-vm will keep going; set it and re-run if the guest panics."
}

fetch() { # url dest [size]
  local url="$1" dest="$2" want="${3:-0}"
  mkdir -p "$(dirname "$dest")"
  if [ "$want" -gt 0 ] && [ -f "$dest" ]; then
    local have
    have=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    [ "$have" -eq "$want" ] && { log "already have $(basename "$dest")"; return 0; }
  fi
  curl -fL --retry 3 -C - -o "$dest" "$url"
  if [ "$want" -gt 0 ]; then
    local have
    have=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    [ "$have" -eq "$want" ] || die "download incomplete: $(basename "$dest") ($have/$want bytes)"
  fi
}

ensure_assets() { # OpenCore + OVMF binaries, pinned to OSX-KVM commit
  mkdir -p "$DATA_DIR"
  local url
  for f in "OpenCore/OpenCore.qcow2:$OPEN_CORE" "OVMF_CODE_4M.fd:$OVMF_CODE" "OVMF_VARS-1920x1080.fd:$OVMF_VARS"; do
    [ -f "${f#*:}" ] || {
      log "fetching $(basename "${f#*:}") from OSX-KVM ($OSXKVM_COMMIT)"
      curl -fsSL --retry 3 -o "${f#*:}" "$ASSETS_BASE/${f%:*}" || die "failed to fetch ${f%:*} — network?"
    }
  done
}

vm_running() {
  [ -f "$PID_FILE" ] || return 1
  kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

vm_display_args() {
  case "$VM_DISPLAY" in
    gtk)  echo "-display gtk" ;;
    vnc)  echo "-display vnc=127.0.0.1:5900" ;;
    none) echo "-display none" ;;
    *)    die "unknown VM_DISPLAY '$VM_DISPLAY' (gtk|vnc|none)" ;;
  esac
}
