
# Maintainer workflow

This directory contains the maintainer-side tooling used to create, verify, publish, and upload SteamOS Waydroid bundles.

The build root can be created either from an official Valve SteamOS image or from a live Steam Deck. The image-based flow is preferred for reproducible builds; the live-Deck flow remains useful for validation against an installed system.

## 1. Configuration

The default compositor versions are:

- wlroots `0.18.2`
- Cage `v0.2.0`

`WLROOTS_VERSION` and `CAGE_VERSION` may be overridden for experimental builds.

For example:

```bash
WLROOTS_VERSION=0.19.0 \
CAGE_VERSION=v0.2.1 \
BUNDLE_VERSION=steamos-3.9.0-wlroots0.19.0-test \
maintainer/enter-build-rootfs.sh
```

`WLROOTS_API_VERSION` is derived automatically from `WLROOTS_VERSION`, so wlroots SONAME handling does not need to be edited when moving between API versions.

`DECK_HOST` is required only when creating the build root from a live Steam Deck.

## 2. Create the SteamOS build root

### From an official Valve SteamOS image

On the maintainer host:

```bash
maintainer/sync-steamos-image-rootfs.sh
```

The script queries Valve's current SteamOS update metadata and presents the available channels, for example:

```text
Select which version to download:
[1] Stable:   3.8.16
[2] Beta:     3.8.24
[3] Preview:  3.8.24
[4] Main:     3.9.0
```

After selecting a channel, the script:

1. resolves the current build ID and SteamOS version;
2. downloads and caches the matching Valve `.img.zst`;
3. decompresses the image;
4. attaches it read-only;
5. mounts the SteamOS `rootfs-A` partition and `var-A` where required;
6. captures the target fingerprint;
7. copies the build-relevant `/usr`, pacman database, and selected `/etc` files;
8. creates the same versioned snapshot/rootfs layout used by the remaining maintainer tools.

The image is not booted and no Steam Deck is required.

Downloaded images are cached beneath:

```text
$BUILD_WORK_ROOT/images/
```

### From a live Steam Deck

To capture the userspace from an installed Steam Deck instead:

```bash
maintainer/sync-steamos-rootfs.sh
```

This method copies the required SteamOS userspace over SSH and creates the same target snapshot/rootfs structure as the image-based method.

Use this path when validating that an official image-derived rootfs matches a real Deck installation, or when a suitable full Valve image is unavailable.

## 3. Enter the build root

After either rootfs sync method succeeds:

```bash
maintainer/enter-build-rootfs.sh
```

This enters the versioned SteamOS build root using `systemd-nspawn`.

The selected `WLROOTS_VERSION` and `CAGE_VERSION` are propagated into the container, so an experimental compositor pair can be tested without changing the default versions in the repository.

For example:

```bash
WLROOTS_VERSION=0.19.0 \
CAGE_VERSION=v0.2.1 \
BUNDLE_VERSION=steamos-3.9.0-wlroots0.19.0-test \
maintainer/enter-build-rootfs.sh
```

## 4. Build the bundle

Inside the build root:

```bash
/repo/maintainer/build-bundle.sh
```

The build script fetches the requested wlroots, Cage, and related source tags.

Cached shallow Git repositories are reused. If the requested tag is not already present, the build tooling fetches that tag and checks it out, allowing the same source cache to be used when switching between versions such as wlroots `0.18.2` and `0.19.0`.

The resulting bundle is written beneath:

```text
$BUILD_WORK_ROOT/out/$BUNDLE_VERSION
```

The wlroots SONAME/API component is derived from `WLROOTS_VERSION`, so the build and verification logic is not tied to a hard-coded `0.18` library name.

## 5. Verify the bundle

Run the normal verification tooling before publishing.

The verifier checks that Cage resolves the wlroots library shipped inside the bundle rather than a host copy, without assuming a particular wlroots ABI version.

A successfully verified bundle contains:

```text
.verified
```

Publishing requires this marker.

## 6. Publish a bundle

Publish a verified bundle with:

```bash
maintainer/publish-bundle.sh
```

Publishing creates immutable bundle artifacts and updates the target catalog.

### Preferred `auto` bundle behavior

The first published bundle for a particular `TARGET_ENVIRONMENT_ID` automatically becomes the preferred bundle selected by `BUNDLE_VERSION=auto`.

If another bundle is later published for the same target fingerprint, it is published side-by-side but does **not** replace the existing preferred bundle.

This allows experimental builds, such as a wlroots 0.19/Cage 0.2.1 bundle, to coexist with a known-good wlroots 0.18 bundle.

To deliberately change the preferred bundle for that exact target fingerprint:

```bash
maintainer/publish-bundle.sh --promote
```

The promotion rules are:

- no preferred bundle exists: the new bundle becomes preferred automatically;
- the bundle is already preferred: no target change is required;
- another bundle is preferred and `--promote` is supplied: the new bundle becomes preferred;
- another bundle is preferred and `--promote` is omitted: the existing preferred bundle remains selected.

For experimental builds, publish normally first and use `--promote` only after the new bundle has been tested on the matching SteamOS target.

### `targets.manifest`

`targets.manifest` is the authoritative mapping used by `BUNDLE_VERSION=auto`.

Conceptually:

```text
target=<TARGET_ENVIRONMENT_ID>|<preferred bundle version>
```

Bundle names are opaque to the resolver. `auto` does not compare wlroots version numbers and does not treat names containing `test` specially.

### `latest.manifest`

`latest.manifest` is updated to the most recently published bundle. It is not the authoritative per-target selection when `targets.manifest` is available.

## 7. Upload to GitHub

After publishing and validating the generated artifacts, use the repository's upload tooling to push them to the GitHub release.

Experimental artifacts may be uploaded without promotion. As long as `targets.manifest` still points to the known-good bundle, normal `BUNDLE_VERSION=auto` installs for that target continue to receive the preferred bundle.

## 8. Recommended experimental wlroots workflow

To test wlroots `0.19.0` with Cage `v0.2.1` while keeping the repository defaults at wlroots `0.18.2` / Cage `v0.2.0`:

```bash
WLROOTS_VERSION=0.19.0 \
CAGE_VERSION=v0.2.1 \
BUNDLE_VERSION=steamos-3.9.0-wlroots0.19.0-test \
maintainer/enter-build-rootfs.sh
```

Inside the container:

```bash
/repo/maintainer/build-bundle.sh
```

Verify the bundle, then publish without promotion:

```bash
BUNDLE_VERSION=steamos-3.9.0-wlroots0.19.0-test \
maintainer/publish-bundle.sh
```

This keeps the existing preferred bundle for the same SteamOS fingerprint.

After testing on the target Steam Deck, promote the final bundle deliberately:

```bash
BUNDLE_VERSION=steamos-3.9.0-wlroots0.19.0-r1 \
maintainer/publish-bundle.sh --promote
```

## 9. Target identity vs bundle build choices

`TARGET_ENVIRONMENT_ID` describes the SteamOS userspace/ABI target.

wlroots and Cage versions are build choices layered on top of that target.

This means multiple compositor builds can legitimately exist for the same SteamOS target fingerprint, while `targets.manifest` selects the single preferred bundle used by `auto`.

## 10. Safety notes

- Keep the known-good bundle preferred until a replacement has been tested.
- Prefer the official Valve image flow for reproducible build roots.
- Use the live-Deck sync flow when validating against a real installed system.
- Do not rely on bundle filename ordering to determine the `auto` target.
- Use `--promote` only when intentionally changing the preferred bundle for a target.
