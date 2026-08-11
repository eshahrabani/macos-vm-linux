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
(~30–60 min). When it reboots, the OpenCore menu offers your new macOS — pick
it, walk through setup, and you're done.

Afterwards, plain boots:

```sh
./bin/macos-vm run       # boot the installed macOS (GTK window)
./bin/macos-vm stop      # clean shutdown (ACPI)
./bin/macos-vm status    # running? disk? installer version?
./bin/macos-vm ssh       # ssh into the VM (port 2222, user: mac — or pass one)
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
| `DISPLAY` | `gtk` | `gtk` window, `vnc` (127.0.0.1:5900), or `none` |
| `SSH_PORT` / `SSH_USER` | `2222` / `mac` | forwarded ssh |
| `CPU_MODEL` | Skylake-Client pin | see `docs/research.md` |
| `MAX_MACOS` | `26` | highest macOS major the installer will resolve |

## Maintenance

```sh
./bin/macos-vm snapshot save before-update      # VM must be stopped
./bin/macos-vm snapshot list
./bin/macos-vm snapshot restore before-update
./bin/macos-vm resize 120G                      # grow the target disk
# inside the VM after resize: diskutil apfs resizeContainer disk0s2 0
```

Files in and out: `scp -P 2222 file mac@localhost:` / `./bin/macos-vm ssh`.

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

- No iMessage/FaceTime: the SMBIOS uses placeholder serials (Xcode and
  Apple-ID sign-in work fine).
- No GPU acceleration — Xcode builds are CPU-bound, but the macOS UI is
  software-rendered (snappy, not Metal).
- SATA is the disk path (macOS has no stock virtio-blk). Put the target disk
  on fast NVMe storage.
