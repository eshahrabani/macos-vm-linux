# macos-vm

Run macOS in a KVM VM on Linux, aimed at near-native performance for Apple
development (Xcode builds inside the VM). Plain bash + QEMU/KVM — nothing to
build, nothing to configure beyond optional knobs.

> Licensing note: macOS's EULA restricts installation to Apple hardware. This
> project is a development tool; running macOS in a VM is your responsibility
> and your call.

## Requirements

- Linux with KVM (`/dev/kvm` accessible), x86-64 with AVX2 (Ventura and newer)
- `qemu-system-x86_64`, `7zip`, `dmg2img`, `curl`, `python3`
  (`sudo apt install qemu-system 7zip dmg2img curl`)
- `echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs` — required for
  macOS; the app checks it on every boot and prints the fix if unset
- ~130 GB free disk (installer ~18 GB + extracted media ~16 GB + 80 GB sparse
  target disk). The sparse target disk only grows as it fills.

## Quick start

```sh
./bin/macos-vm install    # downloads the latest macOS full installer (resumable),
                          # extracts it, and boots the installer VM
```

In the VM: OpenCore's boot menu → pick **macOS Base System** → macOS recovery →
**Install macOS** → select the ~80 GB disk → it formats and installs
(~30–60 min; the first estimate shown is pessimistic). When it reboots, the
OpenCore menu offers your new macOS — pick it, walk through setup, and you're done.

Two installer formats are handled automatically: macOS 26 (Tahoe) ships its
OS payload as a `SharedSupport.dmg` (bootable recovery is fetched from
Apple's osrecovery service — both downloads automatic); Sequoia 15 and
earlier keep the classic `InstallESD.dmg` layout. Set `MAX_MACOS=15` in
`macos-vm.conf` to pin the classic format.

Afterwards, plain boots:

```sh
./bin/macos-vm run       # boot the installed macOS (GTK window)
./bin/macos-vm stop      # clean shutdown (ACPI)
./bin/macos-vm status    # running? disk? installer version?
./bin/macos-vm ssh       # ssh into the VM (port 2222, user: mac — or pass one)
./bin/macos-vm smbios    # show/generate/check/reset the Apple-facing identity
./bin/macos-vm usb       # list/attach/detach a physical iPhone (Xcode development)
./bin/macos-vm tune      # in-guest performance tweaks (see "Performance")
./bin/macos-vm check     # verify host prerequisites
```

`install` is fully resumable — re-run it after an interrupted download and it
continues where it left off. To reinstall the OS: `rm data/disk.qcow2 && ./bin/macos-vm install`.

## Configuration

Copy `vm.conf.example` to `macos-vm.conf` and edit, or export env vars. All
settings have sane defaults:

| var | default | meaning |
|---|---|---|
| `VCPU` / `RAM` / `DISK_SIZE_G` | `8` / `12G` / `80` | VM resources |
| `VM_DISPLAY` | `gtk` | `gtk` window, `vnc` (127.0.0.1:5900), or `none` |
| `SSH_PORT` / `SSH_USER` | `2222` / `mac` | forwarded ssh |
| `CPU_MODEL` | Skylake-Client pin | see `docs/research.md` |
| `MAX_MACOS` | `26` | highest macOS major the installer will resolve |
| `SMBIOS_MODEL` | `iMac19,1` | model the VM presents to Apple (`iMac20,1` — Tahoe-supported, verified for sign-in) |
| `SMBIOS_SERIAL` / `SMBIOS_MLB` / `SMBIOS_UUID` | generated | identity overrides (advanced — see below) |

## Apple ID, SMBIOS, and account safety

Apple ID sign-in **works out of the box** (verified on macOS 26 Tahoe): on
the first `macos-vm run`, the VM is set up to look like real Apple hardware,
and it needs no account plumbing on the host — sign in through the VM's
normal System Settings UI.

The vendored OpenCore ships placeholder serials (`W00000000001`), which
Apple's servers reject — without the setup below, sign-in fails with
"verification failed. An unknown error occurred." On the first run,
`macos-vm`:

1. Generates a real SMBIOS identity (macserial algorithm) and injects it
   into the OpenCore config.plist — serial, MLB, UUID, and a ROM derived
   from your fixed NIC MAC (replacing the static placeholder every OSX-KVM
   user shares). The identity is persisted in `data/smbios.conf` and never
   regenerated, so the VM presents one stable identity to Apple.
2. Installs **VMHide** (a Lilu plugin that hides VMM presence from Apple ID
   processes) plus a Lilu upgrade into the OpenCore image. This is required:
   macOS 15+ blocks sign-in whenever the kernel reports a hypervisor
   (`kern.hv_vmm_present`), even with perfect SMBIOS. Versions are pinned
   (see `docs/research.md`).
3. Re-mounts the image read-only and **verifies the injection persisted**
   before booting — a failed write aborts loudly instead of booting with
   the placeholder identity.

```sh
./bin/macos-vm smbios show      # current identity + conf sync state
./bin/macos-vm smbios check     # advisory checks vs Apple's servers
./bin/macos-vm smbios reset     # back to pristine OpenCore (identity regenerates)
```

Injection mounts the OpenCore image via `qemu-nbd` and needs sudo (once; the
tool prints each command it runs). If sign-in ever fails on iMac19,1, switch
models: `SMBIOS_MODEL=iMac20,1` (Tahoe-supported) in `macos-vm.conf`, then
run `macos-vm run` — the serial/MLB regenerate for the new model, the UUID
stays. This VM was verified on `iMac20,1`.

> **Account safety (read this).** Apple doesn't suspend developer accounts for
> running in a VM — signing/notarizing from virtualized macOS is a normal
> Apple dev flow. The things that actually get accounts flagged are serial
> reuse and identity churn: never inject a serial from a real machine you
> don't own (that's the #1 vector), never copy `data/smbios.conf` to another
> VM, and keep one Apple ID per VM identity. `macos-vm smbios set` refuses
> manual serials unless `ALLOW_REAL_SERIAL=1`. The macOS EULA restricts
> installation to Apple hardware; running this VM is your call.

## Maintenance

```sh
./bin/macos-vm snapshot save before-update      # VM must be stopped
./bin/macos-vm snapshot list
./bin/macos-vm snapshot restore before-update
./bin/macos-vm resize 120G                      # grow the target disk
# inside the VM after resize: diskutil apfs resizeContainer disk0s2 0
```

Files in and out: `scp -P 2222 file mac@localhost:` / `./bin/macos-vm ssh`.

## Performance

The macOS UI is software-rendered: QEMU's `vmware-svga` framebuffer has no
macOS GPU driver, so WindowServer composites every frame on the CPU
(AppleSoftwareRenderer). Render cost scales with pixels and animation
complexity — the genie minimize effect at 1920x1080 is the worst offender
(seconds-long freezes). Tune in the VM, all clickable:

1. **Desktop & Dock** → "Minimize windows using": **Scale effect** — the
   genie effect is a seconds-long freeze under software rendering.
2. **Accessibility → Display**: toggle **Reduce motion** and
   **Reduce transparency**.
3. **Displays**: pick **1280x800** (scaled) — fewer pixels = proportionally
   less WindowServer work.
4. In the GTK window: **View → Zoom to Fit** (or just resize) — scales the
   window up on a 4K monitor without raising the guest resolution.

`./bin/macos-vm tune` automates steps 1-2 over ssh — it needs Remote Login on
in the guest, and a mac account with no password can't be used over ssh. If
ssh isn't set up, tuning by hand is the reliable path; both are equivalent.

Host-side, the VM already boots with a 64 MB SVGA framebuffer and
`cache=writeback` on the disks (I/O stalls don't compound with render stalls).

**GPU acceleration isn't possible on this hardware.** macOS 26 has no NVIDIA
drivers (your RTX 3080 can't accelerate the guest even via passthrough), the
UHD 630 iGPU is disabled in BIOS, and no virtio-gpu/virgl driver exists for
macOS. The only real path is VFIO passthrough of a dedicated AMD GPU (e.g. a
used RX 580 — same chip iMac19,1 ships) — possible, but it needs new
hardware and host-level setup; see `docs/research.md`.

## Copy/paste and files

macOS has no QEMU guest tools: there is no SPICE/virtio guest agent and no
virtio-serial driver for macOS, so QEMU can't share a clipboard with the
guest. Use ssh instead (Remote Login must be on):

```sh
# host -> guest clipboard: pipe text into pbcopy, paste in the VM with Cmd-V
cat notes.txt | ssh -p 2222 mac@localhost pbcopy

# guest -> host clipboard
ssh -p 2222 mac@localhost pbpaste > notes.txt

# files both ways
scp -P 2222 file.txt mac@localhost:
scp -P 2222 mac@localhost:/path/in/vm/file.txt .
```

## iPhone / USB passthrough

Plug a physical iPhone into the host and it's forwarded into the VM for Xcode
deployment and on-device debugging — no host-side tooling, the guest's own
lockdownd handles pairing.

```sh
./bin/macos-vm usb list      # show attached Apple USB devices (find the PID)
./bin/macos-vm usb attach    # hotplug the plugged-in iPhone into the running VM
./bin/macos-vm usb attach 05ac:1281   # or pass a specific VID:PID
./bin/macos-vm usb detach    # remove it from the VM
```

A phone plugged in **at boot** is attached automatically — the default
`USB_PASSTHROUGH=05ac:12a8` (iPhone normal mode) in `macos-vm.conf` adds it to
the QEMU command line. A phone plugged in **mid-session** needs
`usb attach`. No phone present is fine in both cases (it just isn't attached).
The iPhone is attached to a dedicated `usb-ehci` controller: macOS's XHCI
driver fails to enumerate iOS devices on QEMU's xhci (they connect/disconnect
in a loop), while the USB 2.0 EHCI path — all an iPhone needs — is reliable.

First time: unlock the phone, tap **Trust This Computer**, and confirm in the
guest. The iPhone then appears in **System Information → USB** and in
**Xcode → Window → Devices and Simulators**.

Before attaching, make sure the host isn't fighting for the device:

```sh
systemctl --user stop gvfs-afc-volume-monitor.service gvfs-mtp-volume-monitor.service
```

GNOME's gvfs AFC monitor claims iPhones via libusb to auto-mount them; while
it's running, QEMU fails to configure the device (`libusb_set_configuration:
BUSY`) and the guest never enumerates it. `macos-vm usb attach` and
`macos-vm check` warn if it's still active. Restore auto-mount later with
`systemctl --user start gvfs-afc-volume-monitor.service`.

Caveats:

- The iPhone re-enumerates with a different product ID in **recovery** (`0x1281`)
  and **DFU** (`0x1227`) mode, so the fixed default PID drops it there —
  re-attach with that PID or set `USB_PASSTHROUGH=05ac:any`. `any` matches the
  whole Apple vendor, so it also forwards other Apple USB accessories
  (keyboards/mice) into the VM.
- If the host runs `usbmuxd` (libimobiledevice), stop it first — it competes
  for the device: `sudo systemctl stop usbmuxd`.
- The USB device nodes are owned by the `plugdev` group — your user must be in
  it (this host is already set up).
- If the device still won't enumerate on EHCI (e.g. a future macOS drops USB
  2.0 driver support), the Docker-OSX approach is `usbfluxd`: expose the phone
  from the host over usbmuxd TCP and connect from inside the VM — bypasses QEMU
  USB entirely. See `docs/research.md`.

## Super/Command key

macOS maps the keyboard's Windows/Super key to Command, and QEMU delivers it
correctly — the host compositor is what swallows it first. Two steps:

1. **Grab the keyboard** in the VM window: `Ctrl+Alt+G` (release with
   `Ctrl+Alt+G` again). While grabbed, all keys go to the guest.
2. **Clear the host's Super binding** so it stops intercepting: GNOME →
   Settings → Keyboard → View and Customize Shortcuts → System → **"Show the
   overview"** (the Super binding) → press **Backspace** to clear it. Rebind
   it elsewhere if you use it (e.g. Ctrl+Super). Required on Wayland, and
   usually needed on X11 too.

## How it works

Boot chain: OVMF (UEFI) → OpenCore (vendored prebuilt, iMac19,1 SMBIOS) →
macOS. The host downloads Apple's official `InstallAssistant.pkg` for the
latest macOS (Tahoe 26 today, cap via `MAX_MACOS`), extracts it with 7-Zip
(no root), converts with `dmg2img`, and boots the installer from attached
media — so macOS installs offline inside the VM. Apple Developer sign-in
happens inside the VM's normal macOS UI; nothing account-related lives on the
host. Technical pins, sources, and research: `docs/research.md`.

Driver choices (stock macOS, no kexts to install): SATA disk (`ich9-ahci`),
`virtio-net` (AppleVirtIO ships in Big Sur+), `vmware-svga` display, AppleSMC
with the public OSK.

## Known limitations

- No iMessage/FaceTime: sign-in needs a serial registered to Apple (a real
  machine's serial — see the account-safety note above). Apple ID sign-in,
  App Store, and Xcode/Developer workflows work with the generated identity.
- No GPU acceleration — Xcode builds are CPU-bound, but the macOS UI is
  software-rendered. Run `macos-vm tune` + a lower display resolution (see
  "Performance") to keep the UI smooth.
- SATA is the disk path (macOS has no stock virtio-blk). Put the target disk
  on fast NVMe storage.
- The hypervisor fingerprint can't be fully hidden from the kernel
  (`kern.hv_vmm_present` still reads 1 from a shell) — VMHide masks it from
  Apple ID processes, which is what sign-in checks.
