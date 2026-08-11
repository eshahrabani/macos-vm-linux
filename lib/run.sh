#!/usr/bin/env bash
# run/stop/status: qemu lifecycle.

qemu_args() { # $1 = "" | "install" (attach installer media)
  local mode="${1:-}"
  ensure_ignore_msrs
  printf '%s\n' \
    -enable-kvm -m "$RAM" -cpu "$CPU_MODEL" \
    -machine q35 \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
    -smp "$VCPU",sockets=1,cores="$VCPU",threads=1 \
    -device isa-applesmc,osk="$OSK" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -smbios type=2 \
    -device ich9-intel-hda -device hda-duplex \
    -device ich9-ahci,id=sata \
    -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file="$OPEN_CORE" \
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
    $([ "$mode" = install ] && printf '%s\n' \
      -drive id=InstallMedia,if=none,format=raw,file="$BASE_SYSTEM_IMG" \
      -device ide-hd,bus=sata.3,drive=InstallMedia \
      -drive id=InstallPayload,if=none,format=raw,file="$INSTALL_ESD_IMG" \
      -device ide-hd,bus=sata.5,drive=InstallPayload) \
    -drive id=MacHDD,if=none,format=qcow2,file="$DISK" \
    -device ide-hd,bus=sata.4,drive=MacHDD \
    -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
    -device virtio-net-pci,netdev=net0,id=net0,mac="$MAC" \
    -device vmware-svga \
    $(vm_display_args) \
    -monitor unix:"$MONITOR_SOCK",server,nowait \
    -pidfile "$PID_FILE"
}

cmd_run() {
  local mode="${1:-}"
  [ -f "$DISK" ] || die "no VM yet — run 'macos-vm install' first"
  [ -f "$OPEN_CORE" ] && [ -f "$OVMF_CODE" ] && [ -f "$OVMF_VARS" ] || ensure_assets
  if [ "$mode" = install ]; then
    [ -f "$BASE_SYSTEM_IMG" ] && [ -f "$INSTALL_ESD_IMG" ] || die "installer media missing — run 'macos-vm install'"
  fi
  vm_running && die "VM is already running (pid $(cat "$PID_FILE")). Use 'macos-vm stop' or 'macos-vm status'."
  rm -f "$MONITOR_SOCK"

  local -a args=()
  local line
  while IFS= read -r line; do
    # shellcheck disable=SC2206
    args+=($line)
  done < <(qemu_args "$mode")

  log "starting VM ($VCPU vCPU / $RAM, display=$VM_DISPLAY, ssh port $SSH_PORT)"
  nohup qemu-system-x86_64 "${args[@]}" > "$QEMU_LOG" 2>&1 &
  sleep 2
  vm_running || { warn "qemu exited immediately — last log lines:"; tail -5 "$QEMU_LOG" >&2; exit 1; }
  log "VM running (pid $(cat "$PID_FILE")). Log: $QEMU_LOG"
}

cmd_stop() {
  vm_running || die "VM is not running"
  local pid
  pid=$(cat "$PID_FILE")
  log "sending ACPI powerdown (macOS will shut down cleanly)..."
  python3 "$ROOT/lib/hmp.py" "$MONITOR_SOCK" system_powerdown 5 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || { log "VM stopped."; rm -f "$PID_FILE"; exit 0; }
    sleep 1
  done
  warn "no clean shutdown after 30s — terminating"
  kill "$pid" 2>/dev/null || true
  sleep 5
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  log "VM stopped."
}

cmd_status() {
  if vm_running; then
    echo "running (pid $(cat "$PID_FILE"), ssh: ssh -p $SSH_PORT ${SSH_USER}@localhost)"
  else
    echo "not running"
  fi
  [ -f "$DISK" ] && echo "disk: $(qemu-img info -U "$DISK" 2>/dev/null | sed -n 's/.*virtual size: \([0-9]*\) GiB.*/\1GiB/p') ($DISK)"
  [ -f "$VERSION_FILE" ] && echo "installer: $(cat "$VERSION_FILE")"
  echo "data dir: $DATA_DIR"
}
