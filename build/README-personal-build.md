# Personal target-built Waydroid bundle

This directory builds Cage, wlroots, wlr-randr, libglibutil, libgbinder,
python-gbinder, and Waydroid against a copy of the target Steam Deck's SteamOS
userspace. Cage and its private wlroots remain under the `deck` user's home.
The four target-built pacman packages are carried in the verified bundle and
are installed into the SteamOS deployment by the installer or repair mode.
The repository contains recipes and immutable source checksums, not prebuilt
pacman archives.

The current validated host baseline is SteamOS 3.8.16 Stable on x86-64 with:

- glibc 2.41;
- Wayland 1.23.1;
- libdisplay-info 0.3.0 / `libdisplay-info.so.3`;
- no host `libliftoff` package.

## 1. Configure

From the repository root on Fedora:

```bash
cp build/config.example.env .build-config.env
```

Edit `DECK_HOST` in `.build-config.env`. Keep `BUNDLE_VERSION="auto"` so the
target SteamOS release determines the immutable bundle name. Increment
`BUNDLE_REVISION` only when rebuilding changed sources for the same SteamOS
build. The local configuration file is ignored by Git.

## 2. Copy the SteamOS userspace

Enable SSH on the Deck and then run on Fedora:

```bash
build/sync-steamos-rootfs.sh
```

The Deck is only read over SSH. A root-owned build root is materialised on the
Fedora workstation under `BUILD_WORK_ROOT`. The rootfs copy is normalised to
`root:root` ownership for `systemd-nspawn`; the user-owned snapshot remains
unchanged.

Before copying, the script captures SteamOS `VERSION_ID`, `BUILD_ID`, the
kernel, and the installed versions of the relevant userspace packages. These
include glibc, GLib, Python, Wayland, libdisplay-info, libdrm, Mesa, pixman,
libglvnd, libudev/systemd, libinput, libxkbcommon, seatd, hwdata, and XCB. It
stores their deterministic compatibility hash in `target-fingerprint.env` and
derives a name such as:

```text
steamos-3.8.16-b20260716.1-wlroots0.18.2-r2
```

Each release/ABI target gets an independent Fedora snapshot and rootfs under
`BUILD_WORK_ROOT/targets/<SteamOS-build-and-ABI>/`. A later 3.8.17 sync
therefore cannot mix its package database or development payloads into the
retained 3.8.16 environment. Incrementing only `BUNDLE_REVISION` reuses the
same target rootfs rather than duplicating it.

The script obtains the package database location from `pacman-conf DBPath` on
the Deck instead of assuming `/var/lib/pacman`; immutable SteamOS releases may
store it elsewhere. The same absolute path is reproduced in the copied rootfs.

The sync deliberately excludes root-only CUPS, NFS, D-Bus, SSH, ModemManager,
and SteamOS factory helper files which the `deck` account cannot read. None is
part of the compiler, linker, or Cage/wlroots runtime ABI. If an interrupted
sync is rerun, rsync reuses the files already copied. From `/etc`, it copies
only the package/build, linker, user/group, DNS, and public CA configuration
needed inside the build root; it does not attempt to copy Deck secrets.

## 3. Enter and prepare the copied rootfs

```bash
build/enter-build-rootfs.sh
```

Inside the copied SteamOS rootfs, run the preparation script. Do not run
`pacman -Syu`:

```bash
/repo/build/prepare-build-rootfs.sh
```

For an automated preparation followed immediately by the build, Fedora may
instead invoke the rootfs with:

```bash
build/enter-build-rootfs.sh /usr/bin/bash /repo/build/run-private-build-in-rootfs.sh
```

The script initialises the copied rootfs CA trust and package keyring, installs
the build tools (including Cython and setuptools), restores the development
payloads described below, and checks their metadata. Pacman remains interactive
so each transaction can be reviewed. It refuses the development-payload
transaction if a repository
version differs from the installed version recorded in the copied Deck package
database. If pacman nevertheless proposes replacing or upgrading glibc,
Wayland, Mesa, or libdisplay-info, cancel it and investigate.

The deployed SteamOS image is minified: its package database records many
headers and pkg-config files which are omitted from the live image. The
preparation script restores the following development payloads by reinstalling
the same package versions (the underlying command is shown for reference):

```bash
pacman -S \
    glibc linux-api-headers glib2 libsysprof-capture pcre2 python \
    wayland libdisplay-info libdrm libxkbcommon pixman mesa libglvnd \
    systemd-libs seatd libinput hwdata libxcb xcb-util-renderutil \
    libffi libxau libxdmcp xorgproto
```

Do not use `--needed` for this command; these packages are already registered
as installed and must be unpacked again. Review the transaction and continue
only if it reinstalls the same versions with a zero net upgrade. This includes
glibc and Linux API headers because SteamOS removes their standard C headers
from the deployed image. Cancel if pacman proposes any version changes.

The script finishes by confirming the equivalent of:

```bash
pkg-config --modversion \
    glib-2.0 gobject-2.0 libpcre2-8 sysprof-capture-4 \
    wayland-server libdisplay-info libdrm xkbcommon pixman-1 \
    egl gbm glesv2 libudev libseat libinput xcb-renderutil
```

## 4. Build

Still inside the rootfs:

```bash
/repo/build/build-private-bundle.sh
```

The build first creates the four pacman packages in dependency order:

```text
libglibutil -> libgbinder -> python-gbinder -> waydroid
```

Each upstream release archive is checked against `build/packages/sources.lock`.
The two C libraries are installed only into the disposable copied rootfs so the
next package can compile; the live Deck is not touched. The build verifies the
pkg-config metadata and imports the compiled `gbinder` module using the copied
target's Python. It then builds the private compositor. The build stops unless
wlroots needs `libdisplay-info.so.3`, Cage resolves the
private wlroots through a relative RUNPATH, and the bundle excludes host system
libraries. It also rejects libliftoff and Vulkan dependencies because neither
is required for the narrow personal runtime. The wlroots configuration makes
this deterministic by selecting only the GLES2 renderer and explicitly
disabling libliftoff, Vulkan, Xwayland, xcb-errors, and color-management
support. Bundle assembly happens in a staging directory. A verified bundle is
atomically renamed to its final versioned path; incomplete output from an
earlier attempt is preserved with a `.failed-TIMESTAMP` suffix.

Exit the container when finished:

```bash
exit
```

The bundle will be available under its derived target name, for example:

```text
~/steamos-waydroid-personal/out/steamos-3.8.16-b20260716.1-wlroots0.18.2-r2/
```

It contains the captured target fingerprint, the four target-built pacman
packages and source lock, and a checker used again on the real Deck. A
different SteamOS `BUILD_ID`, GLib, or Python creates a separate target instead
of replacing an earlier working build.

## 5. Publish the private artifact on Fedora

Package the verified directory as an immutable archive plus a SHA-256 file:

```bash
build/publish-private-bundle.sh
```

Publishing requires a clean Git worktree so the manifest's source revision
identifies the exact recipes and compatibility patch used for the packages.

The output is placed under `PUBLISH_ROOT`, which defaults to
`~/steamos-waydroid-personal/publish`. Source code remains in Git; target-built
binaries remain in this separate artifact store.
`targets.manifest` maps every retained exact SteamOS target to its preferred
published bundle. Deck-side `BUNDLE_VERSION="auto"` therefore selects a target
match rather than simply using the newest artifact. `latest.manifest` remains
as an informational pointer, and versioned manifests remain available for
manual bundle management.

## 6. Clone the source on the Deck

Clone the Fedora Git checkout over SSH. Later, the same checkout can use a
GitHub remote without changing the Deck-side build artifact workflow:

```bash
git clone \
    --branch personal-safe-architecture \
    --single-branch \
    fedora-build:/home/paulwork/WORK/UniStore/Codes/SteamOS-Waydroid-Installer \
    ~/steamos-waydroid-personal-installer
```

## 7. Configure Deck artifact access

From the Deck checkout:

```bash
cd ~/steamos-waydroid-personal-installer
cp build/deck-config.example.env .deck-config.env
```

The default `ARTIFACT_SOURCE` uses the `fedora-build` SSH alias and the default
Fedora publish directory. Adjust it if either differs. The main installer will
first reuse any installed bundle matching the running SteamOS target; if none
matches, it automatically runs the equivalent of:

```bash
build/install-private-bundle-on-deck.sh
```

The Deck pulls only the matching archive, checks its SHA-256 file, rejects
unsafe archive paths, extracts through a staging directory, runs the ELF
verifier against the real SteamOS host, compares the embedded release and ABI
fingerprint, and switches `current` only after every check passes. Version
directories are immutable. A target mismatch is rejected by default. For a
deliberate compatibility experiment only, use:

```bash
build/install-private-bundle-on-deck.sh --allow-target-mismatch
```

The ELF verifier still runs in override mode. `ARTIFACT_SOURCE` may later be an
HTTPS GitHub Release directory.

## 8. Run the installer locally

The installer or repair mode must be started locally from Konsole in SteamOS
Desktop Mode so graphical prompts and Steam shortcut creation use the real
desktop session. It ensures a matching private bundle is active before
requesting privileged SteamOS changes:

```bash
cd ~/steamos-waydroid-personal-installer
./steamos-waydroid-installer.sh
```

After an atomic SteamOS update, repair reinstalls the target-built host package
set from the matching bundle without recreating or modifying Android data:

```bash
./steamos-waydroid-installer.sh --repair
```

The installer and Game Mode launcher repeat the exact target check. After a
SteamOS rollback, the installer automatically reactivates a compatible bundle
already retained under `~/.local/opt/steamos-waydroid/builds`. If none is
installed, it downloads the catalog entry for that exact target. Re-run the
snapshot, build and publish stages when no matching artifact exists; older
version directories remain available for rollback.

The installed Game Mode launcher also performs local-only selection before
every launch. Switching between SteamOS A/B images therefore reactivates an
already-installed matching bundle without rerunning the main installer or
requiring network access. It never selects an allowed-mismatch bundle and does
not download artifacts; if no local match exists, run the installer or the
Deck-side bundle installation command from Desktop Mode.

## Diagnostic reports

Compatibility mismatches automatically create a Markdown report on the Deck:

```text
~/.local/state/steamos-waydroid/reports/
```

It contains the expected and current SteamOS release, compatibility hashes, a
package-by-package version diff, an assessment, and suggested commands. Reports
are created by Deck artifact installation, installer preflight, and Game Mode
launch checks.

Failures inside `build-private-bundle.sh` create a Fedora-side Markdown report:

```text
~/steamos-waydroid-personal/out/reports/
```

It records the failed build stage and command, target fingerprint, repository
revision, and the last 120 lines of every available Meson log. The terminal
prints the exact report path when one is written. Deck reports are deliberately
retained by the reset script so a failed run can still be diagnosed afterward.

## Full two-machine reset

To delete the entire Fedora build workspace, including the copied SteamOS
rootfs, sources, output and published artifacts:

```bash
build/reset-fedora-build.sh --include-config
```

This retains the Fedora Git checkout and SSH configuration. On the Deck, exit
Steam completely and run:

```bash
./reset-personal-install.sh --full-process
```

Full-process mode removes Waydroid, Android data, Steam shortcuts and artwork,
the private bundle, and the Deck Git checkout. It retains SSH keys and SSH host
configuration so the repository can be cloned again.
