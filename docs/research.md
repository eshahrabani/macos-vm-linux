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
  installed macOS both selectable).
- The ESP inside is a 146.5 MiB FAT16 partition (GPT, LBA 2048), not the
  FAT32 a casual look expects; config.plist lives at `/EFI/OC/config.plist`.
- QEMU `-smbios` args are ignored for these tables: OpenCore's
  `UpdateSMBIOS` rewrites type 1/2/3 from its config.plist. The plist is the
  only injection point.

## SMBIOS identity (lib/smbios.py + lib/smbios.sh, 2026-08-11)

Apple ID sign-in fails ("verification failed. An unknown error occurred.")
with the placeholder serial `W00000000001` — Apple validates serial format +
model on their sign-in stack. Fix: generate a coherent identity and inject it.
**Verified working end-to-end** (Tahoe 26.6.1, iMac20,1 SMBIOS, Apple ID
sign-in succeeds).

- **Algorithm**: port of acidanthera `macserial` (OpenCorePkg
  `Utilities/macserial`, BSD-3-Clause) — the serial/MLB generation and
  checksum (base-34, mod 34 — the `sizeof(alphabet)-1` modulus tripwire) were
  cross-validated both directions against a locally compiled `macserial`
  binary. Tables vendored for exactly two models: iMac19,1
  (`Mac-AA95B1DDAB278B95`) and iMac20,1 (`Mac-CFF7D910A743CAAF` — which also
  matches the recovery.py Tahoe board-id, so the fallback model aligns the
  whole install chain).
- **Injection**: mount OpenCore.qcow2 via `qemu-nbd` (nbd module + sudo,
  same pattern as `ensure_ignore_msrs`), edit `PlatformInfo/Generic`
  {SystemSerialNumber, MLB, SystemUUID, ROM} with plistlib, unmount. ROM is
  set to the MAC-derived value (525400c91827) — the stock placeholder
  `112233445566` is shared by every OSX-KVM user (duplicate-identity vector).
- **Stability (account-safety)**: identity generated once, persisted in
  `data/smbios.conf`, never rotated (serial churn is a device-farming
  signal). `smbios reset` re-fetches the pinned pristine qcow2; the pristine
  plist is also backed up on first injection. `smbios show` reports
  conf-vs-plist drift.
- **Model switch**: `SMBIOS_MODEL=iMac20,1` regenerates serial+MLB for the
  new model (they encode the model), keeps UUID/ROM. iMac19,1 is the default
  (matches the vendored plist); iMac20,1 is the Tahoe-supported fallback if
  sign-in still errors.
- **Checks** (`macos-vm smbios check`, advisory): checkcoverage.apple.com is
  a JS SPA since 2025 — the form/JSON endpoints don't answer without a
  browser session, so it reports unreachable; osrecovery.apple.com answers
  for the board-id+sn tuple (same protocol as lib/recovery.py) but accepts
  placeholders too — neither is a hard validity gate. The authoritative test
  is Apple ID sign-in inside the VM (verified: generated serials + VMHide
  pass; no real machine serials needed).
- **Real serials are a hard "no" by default**: `smbios set` requires
  `ALLOW_REAL_SERIAL=1`; using a serial from a real machine you don't own is
  the documented #1 account-flag vector (serial reuse across accounts), not
  VM detection.

## macOS 15+ blocks Apple ID sign-in in VMs — VMHide (2026-08-11)

Even with a fully valid generated SMBIOS, Apple ID sign-in on Sequoia and
Tahoe fails with "verification failed. An unknown error occurred." The
blocker is not SMBIOS: dockur/macos issue #227 confirms sign-in works on
Sonoma (14) and breaks on Sequoia (15) for everyone, including users with
verified-unused GenSMBIOS serials. macOS 15+ gates sign-in on
`kern.hv_vmm_present` (the same mechanism Apple's "limited iCloud in
Hypervisor.framework VMs" doc describes); KVM reports hv_vmm_present=1 and
there is no QEMU flag to hide it.

Fix (community + project-verified): **VMHide** (Carnations-Botanica/VMHide) —
a Lilu plugin that reroutes `sysctl kern.hv_vmm_present` for Apple ID
processes. Pinned: VMHide 2.0.0 (commit "Update for Tahoe suppot OOB"),
Lilu 1.7.2 (VMHide needs Lilu ≥ 1.7.0; the vendored OSX-KVM image ships
1.6.8, so the image's Lilu.kext is replaced too). Injection: same qemu-nbd
mount — copy both .kext bundles into EFI/OC/Kexts/ and add the VMHide entry
(MinKernel=15.0.0) to Kernel/Add. Kexts are fetched to data/vmhide/ (pinned
URLs) and the state is tracked by SMBIOS_VMHIDE=1 in smbios.conf.

**Persistence bug (fixed 2026-08-11)**: the original cleanup disconnected
the nbd device *before* unmounting — a mounted-but-disconnected nbd discards
its buffered filesystem writes, so the qcow2 silently stayed pristine and
the guest kept booting placeholder SMBIOS (all early sign-in tests were
against the placeholder identity; the "fix didn't work" symptom was this
bug, not Apple). Correct order is umount-then-disconnect. `smbios_verify`
now re-mounts read-only after every injection and dies loudly if the plist
values or VMHide.kext did not persist. (The local test harness's fake umount
masked the bug by syncing the fixture; it now enforces the order.)

Verified on this project: Tahoe 26.6.1, iMac20,1 SMBIOS + VMHide → Apple ID
sign-in succeeds.

## Full-installer-on-host path (user decision; neither reference ships this
## today — OSX-KVM primary flow is recovery-only via fetch-macOS-v2.py)

1. Catalog: PublicRelease
   `https://swscan.apple.com/content/catalogs/others/index-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog`
   (Docker-OSX fetch-macOS.py; also index-11-... variant). Products containing
   an InstallAssistant.pkg are macOS installers; version from the product's
   Distribution plist. Cap at macOS 26 (Tahoe — last Intel; works per
   OSX-KVM). Parse with python3 stdlib plistlib (lib/catalog.py).
2. Download `InstallAssistant.pkg` (~18G) with curl `-C -` resume. Integrity:
   verified against the xar ToC's per-entry sha1 (lib/xar_extract.py).
3. Installer format changed at macOS 26 (Tahoe):
   - **old (15 and earlier)**: 7z x pkg → Payload/InstallESD.dmg →
     dmg2img BaseSystem.dmg→img (boot) + attach InstallESD.img (payload).
     InstallMacOS.dmg layout = createinstallmedia media; offline install.
   - **new (26/Tahoe)**: pkg xar embeds `SharedSupport.dmg` (18G, raw entry)
     containing ONLY the OS payload as mobile assets
     (`Shared Support/com_apple_MobileAsset_MacSoftwareUpdate`) — nothing
     bootable, not even the MacUpdateBrain zip (that's installer plumbing).
     7-Zip 23.01's xar reader FAILS on the 18G entry (misreports sizes).
     Extraction via lib/xar_extract.py (stdlib xar reader; heap-relative
     offsets; <length> = archive bytes, <size> = extracted; "gzip" blocks are
     zlib streams; sha1-verified against the ToC).
   - **Tahoe boot source**: Apple's osrecovery.apple.com macrecovery protocol
     (lib/recovery.py): POST InstallationPayload/RecoveryImage with
     bid=Mac-CFF7D910A743CAAF (Tahoe-supported Intel model), os=latest →
     BaseSystem.dmg (~900M) + chunklist (CNKL). Tokens: AT (image) and CT
     (chunklist) — each pins its exact URL. Chunklist download needs CT;
     md5 in the token is of the CDN response, not usable for verification —
     chunklist sha256 chunk verify is the integrity check (lib/recovery.py).
     Product 140-77966 pairs with pkg 140-77964 (same 26.6.1 generation).
   - Boot: recovery BaseSystem.img (sata.3) + SharedSupport.img raw payload
     (sata.5); recovery's installer reads the mobile assets off the attached
     volume for a local install; network fallback if it insists on newer.
4. `dmg2img` is the only apt gap (missing on this host; OSX-KVM README uses
   it too). No `-q` flag in dmg2img 1.6.7.
5. Boot: OpenCore.qcow2 (sata.2) + boot image (sata.3) + payload volume
   (sata.5) + blank target qcow2 (sata.4).

## arm64 macOS on x86-64: vmapple + TCG (2026-08-21)

Reference (pinned): steelbrain/experiment-macOS-arm64-on-linux-x86
("27on86"), branch `vmapple-tcg`, commit
`48e08c5e9e125d6f8286aef3e5daf90e7027e1e6` — a QEMU fork whose `vmapple`
machine type boots arm64 macOS guests under TCG on an x86-64 Linux host.
State as of the pin: **macOS 13 boots repeatably, headless, 8 vCPU/8 GiB**,
reaching a live SSH service; clean reboot and shutdown work (E0005/E0006).

- **The fork is the QEMU tree**: `git clone` the repo, `git checkout` the
  pin, `./configure --target-list=aarch64-softmmu --enable-debug
  --disable-docs --disable-werror`, `ninja -C build qemu-system-aarch64`.
- **Invocation contract** (mirrored in lib/arm64.sh):
  `-machine vmapple,uuid=<ECID>,accel=tcg,run-installer=off,
  tcg-smp-final-shift=-4` + `-cpu max -smp 8 -m 8G -icount
  shift=0,align=off,sleep=off`; `-bios AVPBooter.vmapple2.bin`; aux+disk
  attached twice each (pflash-style drive + `vmapple-virtio-blk-pci` with
  `share-rw=on,file.locking=off`); `-no-reboot -action
  panic=pause,shutdown=pause`; serial to file; QMP-only (no HMP monitor).
  The guest needs a **writable clone of both disks per boot** (pristine
  imported images are never written; reflink copy, plain copy on ext4).
- **Fork-only machinery the guest depends on**: TCG instantiation of
  vmapple; an implementation-defined pointer-authentication (arm64e PAC)
  compatibility mode that generates deterministic signatures across vCPUs
  (XNU compares kernel function pointers during per-CPU interrupt
  registration); icount shift scaling (shift 0 precise → machine steps the
  shift to -4 after all PSCI CPUs are powered) so XNU's fixed cross-call
  deadlines survive translated SMP execution. None of this is upstream.
- **Guest image provisioning cannot happen on Linux**: macOS arm64 guest
  disks come from Apple's Virtualization.framework (macosvm restore +
  `AVPBooter.vmapple2.bin` from the host) — one-time manual step on any
  Apple Silicon Mac (cloud rental fallback documented in
  `docs/provisioning.md`; free-CI paths are dead: GitHub arm64 runners
  can't nest VZ, Cirrus CI shut down 2026-06-01).
- **Boot-args injection**: the aux image's CHRP system partitions hold
  NVRAM variables; `set-aux-boot-args.py` (fork's scripts/27on86/) sets
  `boot-args=` with adler32 re-checksums; `--check-only` validates the
  NVRAM layout (banks at 0x80000-aligned offsets, one CHRP system
  partition each) — run on every imported aux.
- **ECID**: macosvm.json `machineId` is base64 of a binary plist carrying
  `ECID`; extracted with python3 plistlib (lib/arm64.sh import).
- **Revisit triggers** (do not re-litigate before these): upstream QEMU
  merges TCG support for vmapple; or 27on86's M3 guest-version ladder
  reaches macOS 26/27; or a stock arm64 macOS display driver exists for an
  emulatable device (GUI — the current path has no display at all).
- **Why arm64 is a separate research path, not a flag on the main flow**:
  TCG is ~5-15x slower than KVM (fine here — goal is future-proofing, not
  speed); no GPU/display (headless SSH only); guest ceiling macOS 13 until
  the ladder advances; the x86 path stays the primary, working flow.

## Resource defaults (owner decision)

8 vCPU (1 socket × 8 cores) / 12 GB / 80 GB sparse qcow2 target disk.
Host: Ubuntu 24.04, QEMU 8.2.2, i9-10900K (AVX2 ✓), 31 GB RAM,
/dev/kvm accessible via ACL, 7-Zip 23.01 present.

## UI performance: software rendering (2026-08-11)

`vmware-svga` has no macOS driver — WindowServer composites in software
(AppleSoftwareRenderer), cost scales with pixels × effect complexity. The
genie minimize at 1080p caused 5-10 s freezes. Fixes (all in place):

- Guest-side (`macos-vm tune`): dock minimize-effect → `scale`,
  reduceMotion + reduceTransparency (universalaccess defaults); display set
  to 1280x800 in System Settings; GTK View > Zoom to Fit scales the window
  on the 4K monitor without raising guest res.
- Guest tools: NONE for macOS — no SPICE vdagent, no virtio-serial driver,
  so no QEMU clipboard sharing. Text clipboard via ssh pbcopy/pbpaste; files
  via scp (documented in README).
- Super key: QEMU maps evdev KEY_LEFTMETA (125) → qcode meta_l → USB HID
  usage 0xE3 (Left GUI) → macOS Command (verified against QEMU 8.2.2
  keycodemapdb). Works once the HOST stops eating Super: GTK keyboard grab
  (Ctrl+Alt+G) + clear the compositor's Super binding (GNOME "Show the
  overview" shortcut). Host-side problem, not QEMU's.
- Host-side: `-device vmware-svga,vgamem_mb=64` (VRAM headroom) and
  `cache=writeback` on the disk drives.
- GPU acceleration verdict: not possible on this host. macOS 26 has no
  NVIDIA drivers (RTX 3080 unusable even via VFIO); the UHD 630 iGPU is
  disabled in BIOS (would need BIOS change + experimental VFIO); no
  virtio-gpu/virgl driver exists for macOS. Only real path: VFIO passthrough
  of a dedicated AMD GPU (used RX 580 = Polaris, ships in iMac19,1 so Tahoe
  drivers exist). Documented, not built.
