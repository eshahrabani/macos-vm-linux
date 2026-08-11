#!/usr/bin/env bash
# install: resolve the latest macOS, download the full installer, extract it,
# and boot the installer VM. Every stage is idempotent — re-running resumes.
#
# Two installer formats exist:
#   old (Sequoia 15 and earlier): InstallAssistant.pkg -> Payload/InstallESD.dmg
#       -> {BaseSystem.dmg, SharedSupport/InstallMacOS.dmg}; BaseSystem boots.
#   new (macOS 26/Tahoe): pkg -> SharedSupport.dmg (OS payload only, nothing
#       bootable); the bootable recovery comes from Apple's osrecovery API.

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
  local have=0 src=""
  [ -f "$PKG" ] && have=$(stat -c %s "$PKG")
  [ "$have" -eq "$PRODUCT_SIZE" ] && { log "installer already downloaded"; return; }
  # resume a partial only if it came from the same URL (Apple rotates builds —
  # resuming a different file's URL would silently corrupt the download)
  [ -f "$PKG.url" ] && src=$(cat "$PKG.url")
  if [ "$have" -gt 0 ] && [ "$src" != "$PRODUCT_URL" ]; then
    warn "installer URL changed since the partial download — restarting from scratch"
    rm -f "$PKG"
  fi
  echo "$PRODUCT_URL" > "$PKG.url"
  log "downloading InstallAssistant.pkg (~$((PRODUCT_SIZE / 1024 / 1024 / 1024))G) — resumable, this takes a while"
  curl -fL --retry 3 -C - -o "$PKG" "$PRODUCT_URL" || die "installer download failed — re-run 'macos-vm install' to resume"
  [ "$(stat -c %s "$PKG")" -eq "$PRODUCT_SIZE" ] || die "installer download incomplete — re-run to resume"
}

pkg_format() {
  # "new" (Tahoe: SharedSupport.dmg embedded) vs "old" (InstallESD inside Payload)
  if python3 "$ROOT/lib/xar_extract.py" "$PKG" --list 2>/dev/null | grep -qx SharedSupport.dmg; then
    echo new
  else
    echo old
  fi
}

# --- new-format (macOS 26) extraction -------------------------------------

extract_shared_support() {
  [ -f "$SHARED_SUPPORT" ] && { log "SharedSupport.dmg already extracted"; return; }
  log "extracting SharedSupport.dmg from InstallAssistant.pkg (18G, verified)"
  if ! python3 "$ROOT/lib/xar_extract.py" "$PKG" SharedSupport.dmg "$SHARED_SUPPORT" 2>/dev/null; then
    rm -f "$SHARED_SUPPORT"
    die "SharedSupport.dmg extraction failed (sha1 mismatch?) — re-run 'macos-vm install'"
  fi
}

fetch_recovery() {
  # the bootable recovery is not in the pkg; fetch it from osrecovery.apple.com
  local meta url token cnk cnkt cur
  if [ -f "$RECOVERY_DMG" ] && python3 "$ROOT/lib/recovery.py" verify "$RECOVERY_DMG" "$RECOVERY_CNK" >/dev/null 2>&1; then
    log "recovery image already downloaded and verified"
    return
  fi
  meta="$(python3 "$ROOT/lib/recovery.py" fetch "$RECOVERY_BOARD_ID" latest)" || die "osrecovery query failed"
  url="$(echo "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"
  token="$(echo "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  cnk="$(echo "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["chunklist"])')"
  cnkt="$(echo "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["chunklist_token"])')"
  # tokens pin exact URLs; if the URL rotated, a partial is useless
  cur="$(cat "$RECOVERY_DMG.url" 2>/dev/null || true)"
  if [ -f "$RECOVERY_DMG" ] && [ "$cur" != "$url" ]; then
    warn "recovery URL changed — restarting its download"
    rm -f "$RECOVERY_DMG"
  fi
  echo "$url" > "$RECOVERY_DMG.url"
  log "downloading macOS recovery image (~900M)"
  curl -fL --retry 3 -C - -H "Cookie: AssetToken=$token" -o "$RECOVERY_DMG" "$url" || die "recovery download failed — re-run to resume"
  curl -fsSL -H 'User-Agent: InternetRecovery/1.0' -H "Cookie: AssetToken=$cnkt" -o "$RECOVERY_CNK" "$cnk" || die "recovery chunklist download failed"
  if ! python3 "$ROOT/lib/recovery.py" verify "$RECOVERY_DMG" "$RECOVERY_CNK" >/dev/null 2>&1; then
    warn "recovery image failed verification — restarting its download"
    rm -f "$RECOVERY_DMG"
    curl -fL --retry 3 -C - -H "Cookie: AssetToken=$token" -o "$RECOVERY_DMG" "$url" || die "recovery download failed"
    python3 "$ROOT/lib/recovery.py" verify "$RECOVERY_DMG" "$RECOVERY_CNK" >/dev/null 2>&1 || die "recovery image failed verification twice — network?"
  fi
}

convert_media() {
  [ -f "$BASE_SYSTEM_IMG" ] || {
    log "converting recovery dmg → bootable raw image"
    dmg2img -i "$RECOVERY_DMG" "$BASE_SYSTEM_IMG" >/dev/null 2>&1 || die "dmg2img failed on the recovery image"
  }
  [ -f "$INSTALL_ESD_IMG" ] || {
    log "converting SharedSupport.dmg → raw image (~18G, a few minutes)"
    dmg2img -i "$SHARED_SUPPORT" "$INSTALL_ESD_IMG" >/dev/null 2>&1 || die "dmg2img failed on SharedSupport.dmg"
  }
}

# --- old-format (Sequoia and earlier) extraction --------------------------

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
    dmg2img -i "$ESD_DIR/BaseSystem.dmg" "$BASE_SYSTEM_IMG" >/dev/null 2>&1 || die "dmg2img failed on BaseSystem.dmg"
  }
  # the whole ESD volume is attached to the VM so recovery can reach
  # SharedSupport/InstallMacOS.dmg (same layout as createinstallmedia media)
  [ -f "$INSTALL_ESD_IMG" ] || {
    log "converting InstallESD.dmg → InstallESD.img (~15G, a few minutes)"
    dmg2img -i "$PKG_DIR/Payload/InstallESD.dmg" "$INSTALL_ESD_IMG" >/dev/null 2>&1 || die "dmg2img failed on InstallESD.dmg"
  }
}

# --- shared ----------------------------------------------------------------

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
  if [ "$(pkg_format)" = new ]; then
    extract_shared_support
    fetch_recovery
    convert_media
  else
    extract_pkg
    extract_esd
    convert_images
  fi
  create_disk
  echo "$PRODUCT_TITLE" > "$VERSION_FILE"
  log "installer ready. Launching VM — pick the installer in the OpenCore menu, then in macOS recovery:"
  log "  Install macOS → choose the ~${DISK_SIZE_G}G disk → it formats and installs (~30-60 min)."
  log "  After it finishes, the VM restarts into macOS. Next boot: 'macos-vm run'."
  source "$ROOT/lib/run.sh"
  cmd_run install
}
