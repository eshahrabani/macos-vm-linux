# Research notes — Phase 0 (2026-08-11)

References (pinned):
- OSX-KVM kholia/OSX-KVM @ `4c378a4b5e0b219783683012bec680325eb40719`
- Docker-OSX sickcodes/Docker-OSX @ `aa05a2c9a06aabfc8542c1c373ad1ad0af74ede3`

## QEMU invocation (adapted from OSX-KVM OpenCore-Boot.sh)

- Machine: `-machine q35`
- Firmware: pflash OVMF —
  `-drive if=pflash,format=raw,readonly=on,file=OVMF_CODE_4M.fd` (3.5M)
  + `-drive if=pflash,format=raw,file=OVMF_VARS-1920x1080.fd` (128K),
  vendored from OSX-KVM repo root.
- CPU (works for Sequoia AND Tahoe, fits i9-10900K):
  `-cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,
  vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check`
  (Sonoma-era docs: Penryn → Haswell-noTSX; Sequoia/Tahoe → Skylake-Client.
  `+invtsc,vmware-cpuid-freq=on` required for macOS timekeeping.)
- Apple SMC: `-device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"`
- SATA: `-device ich9-ahci,id=sata`; drives wired as `-device ide-hd,bus=sata.N`
  — OpenCore sata.2, installer media sata.3, target disk sata.4+.
  macOS has no stock virtio-blk driver → SATA is the disk path.
- NIC: `-netdev user,id=net0,hostfwd=tcp::2222-:22
  -device virtio-net-pci,netdev=net0,mac=52:54:00:c9:18:27`
  — virtio-net works Big Sur+ (AppleVirtIO kext ships in macOS).
  High Sierra fallback: vmxnet3.
- Display: `-device vmware-svga` + `-display gtk` (default); VNC/SPICE as
  config option. Input: qemu-xhci + usb-kbd + usb-tablet.
- Audio: `-device ich9-intel-hda -device hda-duplex` (AppleALC.kext ships in
  the vendored OpenCore).
- Host prereq: `echo 1 > /sys/module/kvm/parameters/ignore_msrs`
  (OSX-KVM README: required; Ubuntu default is N).

## OpenCore asset (vendored, no build step)

- `OpenCore/OpenCore.qcow2` (18M) + `OpenCore/config.plist` from OSX-KVM —
  prebuilt bootable EFI qcow2 (Lilu/VirtualSMC/WhateverGreen/AppleALC kexts,
  HfsPlus driver, iMac19,1 SMBIOS with placeholder serial W00000000001).
  `ShowPicker=External` → OpenCore boot menu on every boot (installer and
  installed macOS both selectable). No serialgen/config injection needed
  (iMessage won't work with placeholder serials — documented; Xcode and
  Apple-ID sign-in fine).

## Full-installer-on-host path (user decision; neither reference ships this
## today — OSX-KVM primary flow is recovery-only via fetch-macOS-v2.py)

1. Catalog: PublicRelease
   `https://swscan.apple.com/content/catalogs/others/index-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog`
   (Docker-OSX fetch-macOS.py; also index-11-... variant). Products containing
   an InstallAssistant.pkg are macOS installers; version from the product's
   Distribution plist. Cap at macOS 26 (Tahoe — last Intel; works per
   OSX-KVM). Parse with python3 stdlib plistlib (~40 lines).
2. Download `InstallAssistant.pkg` (~13-15G) with curl `-C -` resume.
3. `7z x InstallAssistant.pkg` → `Payload/InstallESD.dmg`.
   7-Zip 23.01 (Ubuntu `7zip` pkg, already installed) reads DMG, HFS, APFS,
   GPT — verified via `7z i` format table. No root needed.
4. `7z x InstallESD.dmg -oESD/` → yields `BaseSystem.dmg`,
   `BaseSystem.chunklist`, `SharedSupport/InstallMacOS.dmg`.
5. `dmg2img -i BaseSystem.dmg BaseSystem.img` (apt `dmg2img` — the one
   missing package on this host; OSX-KVM README uses the same command).
6. Boot: OpenCore.qcow2 (sata.2) + BaseSystem.img (sata.3) + InstallESD.img
   (sata.5, the whole converted ESD — provides InstallMacOS.dmg to the
   recovery, same layout as createinstallmedia USB media) + blank target
   qcow2 (sata.4). Recovery installs offline; no in-VM re-download.
   Fallback if BaseSystem.img boot hiccups: OpenCore can boot the ESD's
   .IABootFiles directly (HFS+ boot via HfsPlus.efi).

## Resource defaults (owner decision)

8 vCPU (1 socket × 8 cores) / 12 GB / 80 GB sparse qcow2 target disk.
Host: Ubuntu 24.04, QEMU 8.2.2, i9-10900K (AVX2 ✓), 31 GB RAM,
/dev/kvm accessible via ACL, 7-Zip 23.01 present.
