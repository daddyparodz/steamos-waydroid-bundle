# SteamOS Waydroid Bundle

> [!IMPORTANT]
> This is an independently maintained, modified continuation of Ryan Rudolf's
> SteamOS Waydroid Installer. It is not affiliated with or endorsed by the
> original project. Independent modifications began on 17 July 2026. See
> [upstream provenance](UPSTREAM.md) for the incorporated source snapshot,
> authorship, licence history, and current upstream status.

> [!NOTE]
> **AI assistance disclosure:** This continuation was substantially refactored
> during July and August 2026 with OpenAI Codex, an AI coding agent based on
> the GPT-5 model family. Codex assisted with architecture, shell-script
> refactoring, safety checks, documentation, and code review under the human
> maintainer's direction. The exact internal model build or revision identifier
> is not exposed to this repository or session, so no more specific version is
> claimed. The human maintainer selected, tested, and published the changes and
> remains responsible for the resulting software.

SteamOS Waydroid Bundle installs Waydroid on a Steam Deck using host packages,
Cage, wlroots, and wlr-randr built against the Deck's exact SteamOS userspace.
It keeps the persistent Android image under the `deck` user's home so routine
SteamOS host repair can occur without recreating Android applications,
settings, files, or login sessions.

## Compatibility and safety model

The installer supports SteamOS 3.8.x only when a verified bundle has been
published for the Deck's exact target fingerprint. The fingerprint includes
the SteamOS release and build plus relevant compiler, runtime, Python, Wayland,
graphics, input, and system-library versions.

Before requesting sudo access, the installer:

- confirms that it is running locally in SteamOS Desktop Mode;
- checks the SteamOS release and update branch;
- selects an already-installed exact-match bundle or downloads one;
- verifies the archive hash, paths, manifest, ELF dependencies, and target
  fingerprint;
- exits without changing SteamOS or Android when no compatible bundle exists.

A SteamOS version number alone is not treated as proof of binary
compatibility. Normal installation has no option to silently substitute a
bundle built for a different fingerprint.

Bundles contain packages installed into SteamOS as root. Use only the official
artifact source or another source you control and trust.

## Requirements

- Steam Deck running a supported SteamOS 3.8.x stable or beta release;
- an exact published target bundle for that SteamOS userspace;
- Desktop Mode with a working graphical session;
- a sudo password for the `deck` user;
- at least 10 GB free under the home filesystem for a new Android install;
- internet access for source, bundle, and Android-image downloads.

The SteamOS `main` branch is experimental. The installer displays an explicit
warning there, and an exact target bundle is still mandatory.

## Install

In Desktop Mode, open Konsole and run:

```bash
cd ~
git clone --depth=1 \
    https://github.com/pjohno/steamos-waydroid-bundle.git
cd ~/steamos-waydroid-bundle
./steamos-waydroid-installer.sh
```

On first run, the installer creates an ignored machine-local
`.deck-config.env` with mode `0600` and selects the official public bundle
Release. It then obtains the exact bundle before making privileged host
changes.

For a new Android instance, the installer offers:

- Android 13 with Google Play;
- Android 13 without Google Play;
- Android TV 13 with Google Play;
- Android TV 13 without Google Play.

The standard Android images use `waydroid_script` to install libhoudini ARM
translation, Widevine, and fingerprint configuration. The TV images are
provided separately and already contain their required ARM translation and
Widevine components.

The fresh-install path also downloads the
[StevenBlack hosts list](https://github.com/StevenBlack/hosts) variant that
blocks adware, malware, fake-news, gambling, and adult domains. This affects
name resolution inside Waydroid. It can be disabled or updated later through
Waydroid Toolbox.

When installation finishes, the script can create the appropriate Steam
shortcut and offer to return to Gaming Mode. Existing matching shortcuts and
their artwork are preserved.

## Existing installations and repair

Running the installer without an option is intentionally safe on an existing
installation. If `~/Android_Waydroid/waydroid.img` exists, the installer:

1. selects repair mode automatically;
2. validates the persistent image through a read-only mount;
3. obtains the exact host bundle for the current SteamOS target;
4. rebuilds host packages, launchers, shortcuts, and integration;
5. does not initialize or replace Android.

Applications and logins also depend on host-side Android user state under
`~/.local/share/waydroid` and, on older installations, `~/waydroid`. Back up
the image and user-state directories together when the data is important.

After an atomic SteamOS update, run the normal command again:

```bash
cd ~/steamos-waydroid-bundle
./steamos-waydroid-installer.sh
```

If no bundle exists for the updated fingerprint, repair stops before changing
SteamOS or Android. Wait for a compatible bundle, restore a supported SteamOS
deployment, or follow the maintainer build procedure.

## Commands

| Command | Behaviour |
| --- | --- |
| `./steamos-waydroid-installer.sh` | Fresh install when no image exists; otherwise automatic protected repair. |
| `./steamos-waydroid-installer.sh --repair` | Explicitly require the protected existing-image repair path. |
| `./steamos-waydroid-installer.sh --reinstall-android` | Deliberately create a new Android instance after typed confirmation. Existing image and user state are archived first. |
| `./steamos-waydroid-installer.sh --configure-artifacts` | Replace the Deck's bundle source through the advanced configuration wizard. |
| `./steamos-waydroid-installer.sh --uninstall` | Remove host integration while retaining Android state, the checkout, installed bundles, and artifact configuration. |
| `./steamos-waydroid-installer.sh --purge-android` | Delete Android state and reinstall archives while retaining the checkout and verified bundles. |
| `./steamos-waydroid-installer.sh --reset-host-keep-android` | Remove host integration, bundles, artifact configuration, and reports while retaining Android state and the checkout. Useful for first-run testing. |
| `./steamos-waydroid-installer.sh --uninstall-all` | Delete Android state, host integration, bundles, and the Deck-side checkout after typed confirmation. |

Destructive modes explain their scope and require an exact typed phrase. Exit
Steam completely before running uninstall or reset commands.

## Reinstalling Android

`--reinstall-android` is different from repair. When existing state is found,
it archives:

- `~/Android_Waydroid/waydroid.img`;
- `~/.local/share/waydroid`;
- legacy `~/waydroid` state when present.

The new instance does not inherit the previous applications or logins. If
installation fails before the replacement is committed, the installer moves
incomplete replacement state aside and restores the previous image and user
state as a matched set.

## Launching Waydroid

Use the created Waydroid or Nested Desktop entry in Gaming Mode. In Desktop
Mode, the launcher can also be run directly:

```bash
cd ~/Android_Waydroid
./Android_Waydroid_Cage.sh
```

Before every launch, the helper checks the current SteamOS fingerprint and
reactivates an already-installed compatible bundle when possible. After a
SteamOS A/B rollback, this can restore the matching retained bundle without a
network request. If no local match exists, run the installer in Desktop Mode.

## Artifact sources

The normal first run uses the public Release at:

```text
https://github.com/pjohno/steamos-waydroid-bundle/releases/download/bundles
```

Advanced configuration also supports:

- an authenticated private GitHub Release;
- a trusted Fedora build host over SSH and rsync;
- another public HTTP or HTTPS artifact directory.

Changing the source requires explicit confirmation when it is not the official
default. A downloaded checksum proves integrity relative to that source; it
does not make an untrusted source safe.

## Troubleshooting

### No compatible bundle

The error identifies the SteamOS version, build, branch, and target. Do not
bypass the target check for an ordinary installation. A maintainer must build
and publish a bundle against that userspace.

### Installer says it is not in Desktop Mode

Run it locally from Konsole in Desktop Mode. SSH and virtual terminals do not
provide the graphical session needed for prompts and Steam shortcut creation.

### Android-image download is unusually slow

The Android image is obtained from a selected SourceForge mirror. Cancel with
Ctrl-C and retry if the chosen mirror is stalled.

### A shortcut was not recreated

The installer deliberately preserves an existing matching Steam shortcut. To
replace it, delete that shortcut through Steam and run the installer again.

### Compatibility reports

Target mismatches create Markdown reports under:

```text
~/.local/state/steamos-waydroid/reports/
```

When reporting a problem, include:

- SteamOS `VERSION_ID`, `BUILD_ID`, and update branch;
- the exact error message;
- the generated compatibility report when present;
- whether the run was a fresh install, automatic repair, explicit repair, or
  Android reinstall;
- relevant customizations that might affect Waydroid.

Do not post passwords, authentication tokens, private SSH configuration, or
home-network addresses. File issues at
<https://github.com/pjohno/steamos-waydroid-bundle/issues>.

## Maintainers

Normal Deck users should run only `steamos-waydroid-installer.sh`. Helpers
under `libexec/` are internal entry points. Reproducible target capture, build,
publication, reset, and diagnostic procedures are documented in the
[maintainer guide](maintainer/README.md).

Public bundles must be built from a committed revision available in this
repository. Their manifests record that exact source revision and target
fingerprint.

## Credits and licence

- Based on Ryan Rudolf's SteamOS Waydroid Installer; see
  [UPSTREAM.md](UPSTREAM.md) for exact provenance and independent modification
  history.
- [Waydroid](https://github.com/waydroid/waydroid) provides the Android
  container platform.
- [waydroid_script](https://github.com/casualsnek/waydroid_script) provides
  Android extras used by standard-image installation.
- SupeChicken provides the Android TV image source used by the installer.
- Additional authors and contributors are retained in the Git history.

This project is distributed under GNU GPL version 3. See [LICENSE](LICENSE).
