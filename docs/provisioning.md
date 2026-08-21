# Provisioning arm64 macOS guest images

The arm64 (vmapple) path needs guest images that only Apple's
Virtualization.framework can create. There is no Linux-only way to produce
them, and Apple's license forbids redistributing them, so this is the one
manual, one-time step in the arm64 flow.

You need, once, for each macOS version you want to run (macOS 13, 14, 15, 26):

- `disk.img` — the installed macOS guest disk (Virtualization.framework restore)
- `aux.img` — the auxiliary VM boot image
- `macosvm.json` — provisioning metadata (carries the machine ECID/UUID)
- `AVPBooter.vmapple2.bin` — Apple's VM bootloader, from the *host* macOS

## Option A (recommended): any Apple Silicon Mac

Any M1/M2/M3/M4 Mac running macOS 12+ works. Borrowed hardware is fine — the
whole job takes 1-2 hours per version, most of it waiting on downloads.

1. On the Mac, download `macosvm` (Stéphane Sudre's open-source wrapper
   around Virtualization.framework):

   ```sh
   curl -LO https://github.com/s-u/macosvm/releases/download/0.2-2/macosvm-0.2-2-arm64-darwin21.tar.gz
   tar -xzf macosvm-0.2-2-arm64-darwin21.tar.gz && sudo mv macosvm /usr/local/bin/
   ```

2. Download the macOS IPSW you want to run (e.g. `UniversalMac_26.6.1_*.ipsw`
   from ipsw.me or developer.apple.com). 40 GB guest disks are plenty for
   Xcode-era builds and keep transfer sizes sane:

   ```sh
   mkdir macos-vm && cd macos-vm
   ./macosvm --disk disk.img,size=40g --aux aux.img \
     --restore ~/Downloads/UniversalMac_*.ipsw -c 4 -r 8g macosvm.json
   ```

   This takes 15-60 minutes depending on the Mac and IPSW. Repeat for each
   macOS version into its own directory (the ladder needs one disk per
   version; a newer disk can't be re-rolled back to an older macOS).

3. Copy the bootloader out of the host macOS (it is *not* in the IPSW):

   ```sh
   cp /System/Library/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin .
   ```

4. Transfer the directory (macOS 13, 14, 15, 26) to the Linux box — scp,
   rsync, USB stick, whatever moves 40-60 GB.

5. Import on the Linux box (trims the aux 16 KiB header, extracts the ECID,
   validates the NVRAM layout, moves everything into `data/arm64/`):

   ```sh
   ./bin/macos-vm arm64 import /path/to/provisioned-dir
   ./bin/macos-vm arm64 import /path/to/another-dir  # repeat per version
   ```

## Option B: rent a Mac in the cloud (no hardware owned)

If no Mac is borrowable, AWS EC2 Mac instances are the practical hourly
option — they are bare-metal Mac minis, so Virtualization.framework works
(that is what makes this viable; VM-based runners cannot nest it, see below).

- Instance: `mac2-m2.metal` (M2 Mac mini), Dedicated Host, on-demand.
  Billing has a **24-hour minimum allocation** (~$21-26); you pay it once,
  whether you use 1 hour or 24.
- One allocation is enough to provision **all four ladder versions**: the
  restores run in parallel or overnight, then transfer out (~$10-25 egress,
  less if you gzip the disks).
- Steps 1-4 above are identical once you're SSH'd into the instance (it's a
  normal macOS). The first SSH connection uses the EC2 keypair via console
  or the `ec2-mac-init` flow — see the amazon-ec2-mac-getting-started
  sample repo for the one-time setup.

Alternative hourly vendors exist (MacInCloud etc.) but VNC-only access makes
large file transfers painful; AWS is the least friction.

## Dead ends (do not reinvestigate)

- **GitHub Actions arm64 macOS runners** (`macos-14`, `macos-26`, free on
  public repos): they are themselves Virtualization.framework VMs and Apple
  does not support nested virtualization in them — `macosvm` cannot start a
  VM inside the runner. GitHub documents this limitation.
- **Cirrus CI** (the one OSS CI with bare-metal Apple Silicon, free tier for
  open-source projects): shut down 2026-06-01 (Cirrus Labs was acquired by
  OpenAI).
- **Community-shared prebuilt VM images** (UTM/torrents): violates Apple's
  EULA, no integrity guarantee, and the boot contract is version-specific —
  not a foundation to build on.
- **Intel Macs / hackintoshes / the x86 VM**: Virtualization.framework
  macOS guests require Apple Silicon hosts. No x86 path exists.

## Why this can't be automated away

The arm64 macOS boot chain runs through Apple's `AVPBooter` (from the host's
Virtualization.framework) plus the aux image, and the guest OS itself is
installed by Apple's restore flow inside a framework VM. QEMU's `vmapple`
machine implements the same device contract and boots the result — but the
provisioning step itself is Apple's software on Apple's silicon, period.
Every other piece of the arm64 flow (QEMU fork build, boot, SSH, ladder
debugging) happens on this Linux box.