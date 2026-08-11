#!/usr/bin/env bash
# install: resolve latest macOS, download the full installer, extract it,
# and boot the installer VM. Every stage is idempotent — re-running resumes.

resolve_product() {
  log "resolving latest macOS installer (cap: $MAX_MACOS) from Apple's catalog..."
  local out
  out="$(python3 "$ROOT/lib/catalog.py" "$MAX_MACOS")" || die "could not resolve macOS installer from Apple's catalog"
  PRODUCT_VERSION="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
  PRODUCT_URL="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"
  PRODUCT_SIZE="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["size"])')"
  PRODUCT_TITLE="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
  log "found: $PRODUCT_TITLE (macOS $PRODUCT_VERSION, ${PRODUCT_SIZE} bytes)"
}

download_pkg() {
  [ -f "$PKG" ] && [ "$(stat -c %s "$PKG")" -eq "$PRODUCT_SIZE" ] && {
    log "installer already downloaded"
    return
  }
  log "downloading InstallAssistant.pkg (~$((PRODUCT_SIZE / 1024 / 1024 / 1024))G) — resumable, this takes a while"
  curl -fL --retry 3 -C - -o "$PKG" "$PRODUCT_URL" || die "installer download failed — re-run 'macos-vm install' to resume"
  [ "$(stat -c %s "$PKG")" -eq "$PRODUCT_SIZE" ] || die "installer download incomplete — re-run to resume"
}

extract_pkg() {
  [ -f "$PKG_DIR/Payload/InstallESD.dmg" ] && {
    log "installer package already extracted"
    return
  }
  log "extracting InstallESD.dmg from InstallAssistant.pkg (7z, ~5-10 min)"
  7z x -y -o"$PKG_DIR" "$PKG" >/dev/null || die "7z failed on InstallAssistant.pkg"
  [ -f "$PKG_DIR/Payload/InstallESD.dmg" ] || die "InstallESD.dmg not found after extraction"
}

extract_esd() {
  [ -f "$ESD_DIR/BaseSystem.dmg" ] && {
    log "InstallESD already extracted"
    return
  }
  log "extracting BaseSystem + InstallMacOS payload from InstallESD.dmg"
  7z x -y -o"$ESD_DIR" "$PKG_DIR/Payload/InstallESD.dmg" >/dev/null || die "7z failed on InstallESD.dmg"
  [ -f "$ESD_DIR/BaseSystem.dmg" ] || die "BaseSystem.dmg not found in InstallESD"
}

convert_images() {
  [ -f "$BASE_SYSTEM_IMG" ] || {
    log "converting BaseSystem.dmg → BaseSystem.img"
    dmg2img -q "$ESD_DIR/BaseSystem.dmg" "$BASE_SYSTEM_IMG" >/dev/null 2>&1 || die "dmg2img failed on BaseSystem.dmg"
  }
  # the whole ESD volume is attached to the VM so recovery can reach
  # SharedSupport/InstallMacOS.dmg (same layout as createinstallmedia media)
  [ -f "$INSTALL_ESD_IMG" ] || {
    log "converting InstallESD.dmg → InstallESD.img (~15G, a few minutes)"
    dmg2img -q "$PKG_DIR/Payload/InstallESD.dmg" "$INSTALL_ESD_IMG" >/dev/null 2>&1 || die "dmg2img failed on InstallESD.dmg"
  }
}

create_disk() {
  [ -f "$DISK" ] || {
    log "creating target disk: $DISK_SIZE_G"G" (sparse qcow2)"
    qemu-img create -f qcow2 "$DISK" "${DISK_SIZE_G}G" >/dev/null
  }
}

cmd_install() {
  prereq_check
  [ -f "$DISK" ] && die "VM already installed ($DISK exists). To reinstall: delete it, then re-run."
  ensure_assets
  resolve_product
  download_pkg
  extract_pkg
  extract_esd
  convert_images
  create_disk
  echo "$PRODUCT_TITLE" > "$VERSION_FILE"
  log "installer ready. Launching VM — pick the installer in the OpenCore menu, then in macOS recovery:"
  log "  Install macOS → choose the ~${DISK_SIZE_G}G disk → it formats and installs (~30-60 min)."
  log "  After it finishes, the VM restarts into macOS. Next boot: 'macos-vm run'."
  cmd_run install
}
