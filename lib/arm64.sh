#!/usr/bin/env bash
# arm64 macOS (vmapple + TCG) on an x86-64 host.
#
# Research path pinned to the 27on86 project (steelbrain/
# experiment-macOS-arm64-on-linux-x86, vmapple-tcg branch, commit
# 48e08c5e9e125d6f8286aef3e5daf90e7027e1e6): QEMU's vmapple machine under
# TCG boots arm64 macOS guests (headless) on x86-64. See docs/research.md
# for the full state of the art and docs/provisioning.md for the one-time
# guest image provisioning step (needs a Mac; cloud fallback documented).

# --- paths (all under data/arm64, gitignored) ---
ARM64_DIR="${ARM64_DIR:-$DATA_DIR/arm64}"
ARM64_SRC="$ARM64_DIR/qemu-src"
ARM64_QEMU="$ARM64_DIR/qemu-system-aarch64"
ARM64_PROV="$ARM64_DIR/provisioned"
ARM64_WORK="$ARM64_DIR/work"
ARM64_PID="$ARM64_WORK/qemu.pid"
ARM64_QMP="$ARM64_WORK/qmp.sock"
ARM64_SERIAL="$ARM64_WORK/serial.log"

# --- defaults (config via macos-vm.conf / env) ---
ARM64_VCPU="${ARM64_VCPU:-8}"
ARM64_RAM="${ARM64_RAM:-8G}"
ARM64_SSH_PORT="${ARM64_SSH_PORT:-2223}"
ARM64_MAC="${ARM64_MAC:-52:54:00:76:61:70}"
ARM64_VERSION="${ARM64_VERSION:-13}"
ARM64_BOOT_ARGS="${ARM64_BOOT_ARGS:-}"
ARM64_RUN_INSTALLER="${ARM64_RUN_INSTALLER:-off}"

ARM64_PIN="48e08c5e9e125d6f8286aef3e5daf90e7027e1e6"
ARM64_FORK_URL="https://github.com/steelbrain/experiment-macOS-arm64-on-linux-x86"

arm64_version_dir() { # $1 = version (13|14|15|26)
  echo "$ARM64_PROV/$1"
}

arm64_inputs() { # $1 = version; sets FIRMWARE/AUX/DISK/ECID
  local dir ver="$1"
  dir=$(arm64_version_dir "$ver")
  FIRMWARE="$dir/firmware"
  AUX="$dir/aux.img"
  DISK="$dir/disk.img"
  ECID=""
  [ -f "$dir/ecid.conf" ] && ECID=$(sed -n 's/^ECID=//p' "$dir/ecid.conf")
  for f in "$FIRMWARE" "$AUX" "$DISK"; do
    [ -f "$f" ] || die "missing $f — run 'macos-vm arm64 import' (see docs/provisioning.md)"
  done
  [ -n "$ECID" ] || die "missing ECID for version $ver — re-import"
}

arm64_qemu() {
  [ -x "$ARM64_QEMU" ] || die "arm64 emulator not built — run 'macos-vm arm64 build'"
}

# --- build: the 27on86 QEMU fork (not upstream; pinned) ---
arm64_build() {
  require git "apt install git"
  mkdir -p "$ARM64_DIR"
  if [ ! -d "$ARM64_SRC/.git" ]; then
    log "cloning 27on86 QEMU fork (this is the vmapple+TCG research tree)"
    git clone --filter=blob:none "$ARM64_FORK_URL" "$ARM64_SRC"
  fi
  (
    cd "$ARM64_SRC"
    git checkout -q "$ARM64_PIN" || die "pin $ARM64_PIN not found in fork — fork moved?"
  )
  local bd="$ARM64_SRC/build"
  [ -f "$bd/config-host.mak" ] || {
    log "configuring qemu-system-aarch64 (aarch64-softmmu, debug)"
    (cd "$ARM64_SRC" && ./configure --target-list=aarch64-softmmu --enable-debug --disable-docs --disable-werror)
  }
  log "building — this takes a while (ninja, single target)"
  ninja -C "$bd" qemu-system-aarch64
  cp "$bd/qemu-system-aarch64" "$ARM64_QEMU"
  log "built $ARM64_QEMU"
}

# --- import: adopt a Virtualization.framework-provisioned guest dir ---
# DIR must contain disk.img, aux.img, AVPBooter.vmapple2.bin, macosvm.json
# (see docs/provisioning.md). Trims the aux 16 KiB header, extracts the
# machine ECID, validates the NVRAM layout, moves everything under
# data/arm64/provisioned/<version>/.
arm64_import() {
  local dir="${1:-}" ver="${2:-}" ecid
  [ -n "$dir" ] && [ -d "$dir" ] || die "usage: macos-vm arm64 import <dir> <version>"
  ver="${2:-$(basename "$dir")}"
  case "$ver" in 13|14|15|26) ;; *) die "version must be 13|14|15|26 (got '$ver')" ;; esac
  for f in disk.img aux.img AVPBooter.vmapple2.bin macosvm.json; do
    [ -f "$dir/$f" ] || die "missing $dir/$f — provisioning incomplete (docs/provisioning.md)"
  done

  ecid=$(python3 - "$dir/macosvm.json" <<'PY'
import base64, json, plistlib, sys
machine_id = json.load(open(sys.argv[1]))["machineId"]
plist = plistlib.loads(base64.b64decode(machine_id))
print(plist["ECID"])
PY
  )
  [ -n "$ecid" ] || die "could not extract ECID from macosvm.json"

  local target
  target=$(arm64_version_dir "$ver")
  mkdir -p "$target"
  cp --reflink=auto "$dir/disk.img" "$target/disk.img"
  cp "$dir/AVPBooter.vmapple2.bin" "$target/firmware"
  dd if="$dir/aux.img" of="$target/aux.img" bs=$((0x4000)) skip=1 status=none
  printf 'ECID=%s\n' "$ecid" > "$target/ecid.conf"

  arm64_check_aux "$target/aux.img"
  log "imported macOS $ver (ECID $ecid) -> $target"
}

arm64_check_aux() { # $1 = aux image; validates NVRAM layout with the fork's checker
  [ -f "$ARM64_SRC/scripts/27on86/set-aux-boot-args.py" ] || \
    die "fork checkout missing — run 'macos-vm arm64 build'"
  python3 "$ARM64_SRC/scripts/27on86/set-aux-boot-args.py" --check-only "$1" \
    || die "aux NVRAM layout invalid — wrong macosvm version? re-provision"
}

arm64_list() {
  if [ ! -d "$ARM64_PROV" ]; then
    echo "no arm64 guest images imported (docs/provisioning.md)"
    return 0
  fi
  for dir in "$ARM64_PROV"/*/; do
    [ -d "$dir" ] || continue
    local ver
    ver=$(basename "$dir")
    local size
    size=$(du -h "$dir/disk.img" 2>/dev/null | cut -f1)
    printf 'macOS %-3s disk %-8s ECID %s\n' "$ver" "$size" \
      "$(sed -n 's/^ECID=//p' "$dir/ecid.conf" 2>/dev/null)"
  done
}

arm64_running() {
  [ -f "$ARM64_PID" ] && kill -0 "$(cat "$ARM64_PID")" 2>/dev/null
}

arm64_qemu_args() { # $1 = version
  arm64_qemu
  arm64_inputs "$1"
  [ -d "$ARM64_WORK" ] || mkdir -p "$ARM64_WORK"
  local aux_work="$ARM64_WORK/aux.img" disk_work="$ARM64_WORK/disk.img"
  local machine="vmapple,uuid=$ECID,accel=tcg,run-installer=$ARM64_RUN_INSTALLER"
  [ "${ARM64_VCPU:-1}" -gt 1 ] && machine="$machine,tcg-smp-final-shift=-4"

  # Writable clones per boot (the guest writes its disks; the pristine
  # imported images must stay untouched). reflink when the fs supports it,
  # else a plain copy (the imported disks are sparse, so it is cheap).
  cp --reflink=auto "$AUX" "$aux_work"
  cp --reflink=auto "$DISK" "$disk_work"
  if [ -n "$ARM64_BOOT_ARGS" ]; then
    python3 "$ARM64_SRC/scripts/27on86/set-aux-boot-args.py" "$aux_work" "$ARM64_BOOT_ARGS"
  fi

  printf '%s\n' \
    -machine "$machine" \
    -cpu max \
    -smp "$ARM64_VCPU" \
    $([ "${ARM64_VCPU:-1}" -gt 1 ] && echo "-icount shift=0,align=off,sleep=off") \
    -m "$ARM64_RAM" \
    -display none \
    -monitor none \
    -serial "file:$ARM64_SERIAL" \
    -qmp "unix:$ARM64_QMP,server=on,wait=off" \
    -action panic=pause,shutdown=pause \
    -no-reboot \
    -bios "$FIRMWARE" \
    -drive "if=pflash,format=raw,file.filename=$aux_work,file.locking=off" \
    -drive "if=pflash,format=raw,file.filename=$disk_work,file.locking=off" \
    -drive "if=none,format=raw,file.filename=$aux_work,file.locking=off,id=aux" \
    -device vmapple-virtio-blk-pci,variant=aux,drive=aux,share-rw=on \
    -drive "if=none,format=raw,file.filename=$disk_work,file.locking=off,id=root" \
    -device vmapple-virtio-blk-pci,variant=root,drive=root,share-rw=on \
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:$ARM64_SSH_PORT-:22" \
    -device "virtio-net-pci,netdev=net0,mac=$ARM64_MAC"
}

arm64_run() {
  local ver="${1:-$ARM64_VERSION}"
  arm64_inputs "$ver"
  arm64_running && die "arm64 VM already running (pid $(cat "$ARM64_PID"))"
  arm64_qemu
  rm -f "$ARM64_QMP" "$ARM64_PID"

  local -a args=()
  local line
  while IFS= read -r line; do
    # shellcheck disable=SC2206
    args+=($line)
  done < <(arm64_qemu_args "$ver")

  log "starting arm64 macOS $ver ($ARM64_VCPU vCPU / $ARM64_RAM, TCG, ssh port $ARM64_SSH_PORT)"
  log "this is software emulation — boot takes minutes; watch: macos-vm arm64 console"
  nohup "$ARM64_QEMU" "${args[@]}" > "$ARM64_DIR/qemu.log" 2>&1 &
  echo $! > "$ARM64_PID"
  sleep 2
  arm64_running || { warn "qemu exited immediately — last log lines:"; tail -5 "$ARM64_DIR/qemu.log" >&2; exit 1; }
  log "arm64 VM running (pid $(cat "$ARM64_PID")). Serial: $ARM64_SERIAL"
}

arm64_stop() {
  arm64_running || die "arm64 VM is not running"
  local pid
  pid=$(cat "$ARM64_PID")
  log "sending QMP system_powerdown (macOS shuts down, VM pauses)..."
  python3 "$ROOT/lib/qmp.py" "$ARM64_QMP" system_powerdown 2>/dev/null || true
  local i st
  for i in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || { log "arm64 VM stopped."; rm -f "$ARM64_PID"; return 0; }
    st=$(python3 "$ROOT/lib/qmp.py" "$ARM64_QMP" query-status 2>/dev/null || echo '{"error":1}')
    if [ "$st" = '{"status": "paused"}' ]; then
      log "guest shut down (paused) — quitting qemu"
      python3 "$ROOT/lib/qmp.py" "$ARM64_QMP" quit 2>/dev/null || true
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      break
    fi
    sleep 1
  done
  kill -0 "$pid" 2>/dev/null && { warn "no clean shutdown after 120s — terminating"; kill "$pid" 2>/dev/null || true; sleep 5; kill -9 "$pid" 2>/dev/null || true; }
  rm -f "$ARM64_PID"
  log "arm64 VM stopped."
}

arm64_status() {
  if arm64_running; then
    echo "running (pid $(cat "$ARM64_PID"), ssh: ssh -p $ARM64_SSH_PORT ${SSH_USER}@localhost)"
  else
    echo "not running"
  fi
  arm64_list
}

arm64_ssh() {
  arm64_running || die "arm64 VM is not running"
  exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "$ARM64_SSH_PORT" "${1:-$SSH_USER}@localhost"
}

arm64_console() {
  arm64_running || die "arm64 VM is not running"
  exec tail -f "$ARM64_SERIAL"
}