# Personal private Cage build

This directory builds Cage, wlroots, and wlr-randr against a read-only copy of
the target Steam Deck's SteamOS userspace. The resulting bundle is installed
under the `deck` user's home directory. It must never contain or replace
SteamOS display libraries.

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

Edit `DECK_HOST` in `.build-config.env`. The local file is ignored by Git.

## 2. Copy the SteamOS userspace

Enable SSH on the Deck and then run on Fedora:

```bash
build/sync-steamos-rootfs.sh
```

The Deck is only read over SSH. A root-owned build root is materialised on the
Fedora workstation under `BUILD_WORK_ROOT`. The rootfs copy is normalised to
`root:root` ownership for `systemd-nspawn`; the user-owned snapshot remains
unchanged.

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

Inside the copied SteamOS rootfs, install build-only tools. Do not run
`pacman -Syu`:

```bash
pacman -S --needed \
    base-devel git meson ninja patchelf scdoc wayland-protocols
```

Review the transaction before accepting it. If pacman proposes replacing or
upgrading glibc, Wayland, Mesa, or libdisplay-info, cancel it and investigate.

The deployed SteamOS image is minified: its package database records many
headers and pkg-config files which are omitted from the live image. Restore
those development payloads inside the copied rootfs by reinstalling the same
package versions:

```bash
pacman -S \
    wayland libdisplay-info libdrm libxkbcommon pixman mesa libglvnd \
    systemd seatd libinput hwdata libxcb xcb-util-renderutil
```

Do not use `--needed` for this command; these packages are already registered
as installed and must be unpacked again. Review the transaction and continue
only if it reinstalls the same versions. Cancel if it proposes version changes.

Confirm the key metadata before building:

```bash
pkg-config --modversion \
    wayland-server libdisplay-info libdrm xkbcommon pixman-1 \
    egl gbm glesv2 libudev libseat libinput xcb-renderutil
```

## 4. Build

Still inside the rootfs:

```bash
/repo/build/build-private-bundle.sh
```

The build stops unless wlroots needs `libdisplay-info.so.3`, Cage resolves the
private wlroots through a relative RUNPATH, and the bundle excludes host system
libraries. It also rejects libliftoff and Vulkan dependencies because neither
is required for the narrow personal runtime. The wlroots configuration makes
this deterministic by selecting only the GLES2 renderer and explicitly
disabling libliftoff, Vulkan, Xwayland, xcb-errors, and color-management
support.

Exit the container when finished:

```bash
exit
```

The bundle will be available at:

```text
~/steamos-waydroid-personal/out/personal-1/
```

## 5. Verify again on the Deck

Copy the bundle into a versioned user directory:

```bash
ssh "$DECK_HOST" 'mkdir -p ~/.local/opt/steamos-waydroid/builds/personal-1'

rsync -a \
    ~/steamos-waydroid-personal/out/personal-1/ \
    "$DECK_HOST:~/.local/opt/steamos-waydroid/builds/personal-1/"

ssh "$DECK_HOST" \
    'ln -sfn builds/personal-1 ~/.local/opt/steamos-waydroid/current'
```

Run the verifier against the real Deck host before changing the launcher:

```bash
rsync -a build/verify-private-bundle.sh build/lib \
    "$DECK_HOST:~/steamos-waydroid-verify/"

ssh "$DECK_HOST" \
    '~/steamos-waydroid-verify/verify-private-bundle.sh \
     ~/.local/opt/steamos-waydroid/current'
```
