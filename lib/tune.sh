#!/usr/bin/env bash
# tune: apply in-guest performance tweaks over SSH. The vmware-svga
# framebuffer has no macOS GPU driver — WindowServer composites in software
# (AppleSoftwareRenderer), so animation cost scales with pixels and effect
# complexity. The genie minimize effect and translucency are the worst
# offenders at 1080p. Requires Remote Login enabled in the guest and the VM
# running (password auth works; ssh keys are nicer for repeat runs).

set -euo pipefail

tune_ssh() { # run a command in the guest (password prompt if no key)
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -p "$SSH_PORT" "$SSH_USER@localhost" "$@"
}

cmd_tune() {
  vm_running || die "VM is not running"
  log "applying performance tweaks in the guest (ssh $SSH_USER@localhost:$SSH_PORT)"
  tune_ssh bash -s <<'EOF'
set -e
defaults write com.apple.dock minimize-effect -string scale
defaults write com.apple.universalaccess reduceMotion -bool true
defaults write com.apple.universalaccess reduceTransparency -bool true
killall Dock 2>/dev/null || true
echo "minimize-effect:    $(defaults read com.apple.dock minimize-effect)"
echo "reduceMotion:       $(defaults read com.apple.universalaccess reduceMotion)"
echo "reduceTransparency: $(defaults read com.apple.universalaccess reduceTransparency)"
EOF
  log "done — minimize/genie frozen, motion + transparency reduced."
  log "display: set System Settings > Displays to 1280x800 (scaled) for the"
  log "  biggest win; WindowServer renders in software, fewer pixels = faster."
  local res
  res="$(tune_ssh system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/.*Resolution: \([0-9]*\) x \([0-9]*\).*/\1x\2/p' | head -1)"
  [ -n "$res" ] && log "guest display is currently ${res}"
}
