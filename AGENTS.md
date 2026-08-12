# AGENTS.md

## Project
Linux app that runs macOS in a VM on Linux for Apple development, targeting
near-native performance (Xcode builds inside the VM). Greenfield — repository
is currently empty and not yet a git repo; run `git init` before the first
real change.

## Core constraints (non-negotiable)
- Extremely simple; efficiency and usable UX first. Challenge any design that
  adds moving parts — this project exists because existing options are too
  complex.
- No host-side Apple auth. The user logs into their Apple Developer account
  inside the VM's normal macOS UI — never build account/login plumbing into
  the host app.
- The app must automatically download the OS image — no manual user download
  steps.

## Tech approach
- Shell + QEMU/KVM (decided). KVM is the performance accelerator; QEMU the
  machine layer. Keep scripts plain bash, no framework.
- Study OSX-KVM and Docker-OSX as references; the goal is to be simpler than
  both.

## Repo conventions
- Lint (no task runner, no tests yet):
  `bash -n bin/macos-vm lib/*.sh && python3 -m py_compile lib/*.py`
- Runtime state lives in `data/` (gitignored): downloaded installer, extracted
  media, target disk, pid/log files. `bin/macos-vm` is the only entrypoint;
  config via `macos-vm.conf` or env vars (defaults in `lib/common.sh`).
- Vendored binaries (OpenCore.qcow2, OVMF fds) are fetched at install time,
  pinned to OSX-KVM commit `4c378a4b5e0b219783683012bec680325eb40719`
  (see `docs/research.md`). Bump the pin deliberately, never casually.

## History
- 2026-08-11: project scoped (goal, constraints, tech stack decided by owner).
  Update this log when decisions change so future sessions don't relitigate them.
- 2026-08-11: Phase-0 research done against OSX-KVM + Docker-OSX; technical
  pins decided (see `docs/research.md` if kept, else README). Key decisions:
  q35 + OVMF pflash + vendored OSX-KVM OpenCore.qcow2 (iMac19,1 SMBIOS);
  `-cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,
  vmware-cpuid-freq=on` (Sequoia/Tahoe-capable, fits i9-10900K);
  ich9-ahci SATA disks (macOS has no stock virtio-blk), virtio-net-pci
  (AppleVirtIO kext ships in Big Sur+); vmware-svga + GTK display;
  isa-applesmc with public OSK; host requires kvm ignore_msrs=1.
  Full-installer-on-host path: PublicRelease sucatalog → latest
  InstallAssistant.pkg (cap macOS 26) → 7z (23.01, reads DMG+HFS) →
  InstallESD.dmg → 7z → dmg2img BaseSystem.dmg→img (only root-free gap,
  `apt install dmg2img`); boot BaseSystem.img + attach InstallESD.img for
  InstallMacOS.dmg payload (offline install). SMBIOS: vendor config
  placeholder serials (Xcode/Apple-ID sign-in fine; iMessage won't work —
  documented).
- 2026-08-11: macOS 26 (Tahoe) changed the installer format mid-install:
  pkg now embeds SharedSupport.dmg (mobile-asset OS payload only, nothing
  bootable; 7z 23.01 can't read the 18G xar entry). Added lib/xar_extract.py
  (stdlib xar reader, sha1-verified) + lib/recovery.py (osrecovery
  macrecovery protocol: bootable recovery + CNKL chunklist; tokens AT/CT
  pin exact URLs). install.sh now branches old/new format; old path kept
  for MAX_MACOS=15 (Sequoia). Tahoe: boot recovery BaseSystem.img + attach
  SharedSupport.img payload (offline if recovery accepts local assets,
  else in-VM download).
- 2026-08-11: Apple ID sign-in failed on the installed VM (placeholder
  SMBIOS `W00000000001` in the vendored OpenCore). Added lib/smbios.py
  (macserial algorithm port, cross-validated against the C binary; models
  iMac19,1 default + iMac20,1 Tahoe-supported fallback) + lib/smbios.sh
  (qemu-nbd + sudo injection into EFI/OC/config.plist; identity persisted in
  data/smbios.conf, never rotated; ROM set from fixed MAC; `smbios
  show|generate|set|check|reset`; auto-inject on first `run`; real serials
  refused without ALLOW_REAL_SERIAL=1). Apple-side checks are advisory only
  (checkcoverage is a JS SPA; osrecovery accepts placeholders). Sign-in is
  the authoritative test; iMac20,1 is the fallback if it still errors.
- 2026-08-11: Apple ID sign-in STILL failed with valid generated SMBIOS on
  both iMac19,1 and iMac20,1. Root cause found: macOS 15+ gates sign-in on
  kern.hv_vmm_present (KVM reports 1, cannot be hidden by QEMU flags) —
  dockur/macos#227 proves Sonoma works / Sequoia+ fails for everyone
  regardless of serial. Fix: VMHide (Lilu plugin) + Lilu upgrade to 1.7.2,
  injected into the OpenCore image in the same qemu-nbd mount (Kexts sync +
  Kernel/Add entry, MinKernel=15.0.0); pinned VMHide 2.0.0 (Tahoe support),
  Lilu 1.7.2 (vendored image ships 1.6.8). Tracked by SMBIOS_VMHIDE=1 in
  smbios.conf.
- 2026-08-11: injection-persistence bug found: smbios_cleanup disconnected
  the nbd device BEFORE unmounting, silently dropping all filesystem writes —
  the qcow2 stayed pristine (guest always booted placeholder SMBIOS; every
  sign-in test was invalid). Harness's fake umount masked it (it synced the
  fixture). Fixed: umount-then-disconnect order + `smbios_verify` re-mounts
  read-only after every injection and dies loudly if the write did not
  persist or VMHide.kext is missing. Harness now enforces order (fake
  disconnect fails if the mount is still populated).
- 2026-08-11: Apple ID sign-in VERIFIED WORKING (Tahoe 26.6.1, iMac20,1
  SMBIOS, generated serials — no real machine serials needed). The whole
  chain is confirmed: placeholder-SMBIOS rejection + macOS 15+ hv_vmm_present
  sign-in gate (VMHide) were both real blockers; the persistence bug had
  hidden that the earlier fixes were never actually applied to the guest.
  README/research docs updated to the verified state.
- Tooling: lint = `bash -n` on all scripts (no task runner, no tests yet).
