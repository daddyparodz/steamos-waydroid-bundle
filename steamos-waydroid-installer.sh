#!/bin/bash

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

REPAIR_MODE=false
CONFIGURE_ARTIFACTS=false
UNINSTALL_MODE=false
FULL_UNINSTALL_MODE=false
PURGE_ANDROID_MODE=false
RESET_HOST_KEEP_ANDROID_MODE=false
REINSTALL_ANDROID_MODE=false
AUTO_REPAIR_MODE=false
ANDROID_REINSTALL_HAS_EXISTING=false
usage () {
	echo "usage: $0 [--repair | --reinstall-android | --configure-artifacts | --uninstall | --purge-android | --uninstall-all | --reset-host-keep-android]" >&2
}
if [ "$#" -gt 1 ]
then
	usage
	exit 1
fi
case "${1:-}" in
	"") ;;
	--repair) REPAIR_MODE=true ;;
	--reinstall-android) REINSTALL_ANDROID_MODE=true ;;
	--configure-artifacts) CONFIGURE_ARTIFACTS=true ;;
	--uninstall) UNINSTALL_MODE=true ;;
	--purge-android) PURGE_ANDROID_MODE=true ;;
	--uninstall-all) FULL_UNINSTALL_MODE=true ;;
	--reset-host-keep-android) RESET_HOST_KEEP_ANDROID_MODE=true ;;
	*)
		usage
		exit 1
		;;
esac

clear

echo SteamOS Waydroid Installer - target-built public bundle edition
echo https://github.com/pjohno/steamos-waydroid-bundle
echo Based on the installer by ryanrudolf / 10MinuteSteamDeckGamer
sleep 2

# define variables here
if SCRIPT_VERSION_SHA=$(git rev-parse --short HEAD 2> /dev/null)
then
	:
elif [ -r .source-version ]
then
	SCRIPT_VERSION_SHA=$(cat .source-version)
else
	SCRIPT_VERSION_SHA=development
fi
if [ ! -r /etc/os-release ]
then
	echo SteamOS release metadata is unavailable. >&2
	exit 1
fi
# shellcheck source=/dev/null
source /etc/os-release
STEAMOS_VERSION_ID=${VERSION_ID:-unknown}
STEAMOS_BUILD_ID=${BUILD_ID:-unknown}
STEAMOS_BRANCH=$(steamos-select-branch -c 2> /dev/null || true)
WORKING_DIR=$SCRIPT_DIR
DECK_CONFIG_FILE=${DECK_CONFIG_FILE:-$WORKING_DIR/.deck-config.env}
DECK_RUNTIME=$WORKING_DIR/libexec/steamos-waydroid
ARTIFACT_CONFIGURATOR=$DECK_RUNTIME/configure-artifacts.sh
ANDROID_HOME=$HOME/Android_Waydroid
WAYDROID_IMAGE=$ANDROID_HOME/waydroid.img
WAYDROID_USER_STATE=$HOME/.local/share/waydroid
WAYDROID_LEGACY_USER_STATE=$HOME/waydroid
# shellcheck source=libexec/steamos-waydroid/installer-functions.sh
source "$DECK_RUNTIME/installer-functions.sh"
# shellcheck source=libexec/steamos-waydroid/installer-sanity-checks.sh
source "$DECK_RUNTIME/installer-sanity-checks.sh"
if [ "$FULL_UNINSTALL_MODE" = true ]
then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --full-process
	exit $?
elif [ "$RESET_HOST_KEEP_ANDROID_MODE" = true ]
then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --reset-host-keep-android
	exit $?
elif [ "$PURGE_ANDROID_MODE" = true ]
then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --purge-android
	exit $?
elif [ "$UNINSTALL_MODE" = true ]
then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --keep-android
	exit $?
elif [ "$CONFIGURE_ARTIFACTS" = true ]
then
	if ! STEAMOS_WAYDROID_INTERNAL=1 "$ARTIFACT_CONFIGURATOR" --force
	then
		echo Artifact configuration was not completed. >&2
		exit 1
	fi
	exit 0
fi

# A persistent Android image is authoritative installation state. A normal run
# repairs the host around it; Android replacement requires an explicit option.
if [ "$REPAIR_MODE" != true ] && [ "$REINSTALL_ANDROID_MODE" != true ] && \
	{ [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; }
then
	REPAIR_MODE=true
	AUTO_REPAIR_MODE=true
fi

if [ "$REPAIR_MODE" != true ] && [ "$REINSTALL_ANDROID_MODE" != true ] && \
	[ ! -e "$WAYDROID_IMAGE" ] && [ ! -L "$WAYDROID_IMAGE" ] && \
	{ [ -e "$WAYDROID_USER_STATE" ] || [ -L "$WAYDROID_USER_STATE" ] || \
	  [ -e "$WAYDROID_LEGACY_USER_STATE" ] || [ -L "$WAYDROID_LEGACY_USER_STATE" ]; }
then
	echo Existing Android user data was found without its matching persistent image. >&2
	echo Restore the image before running repair, or use --reinstall-android to archive >&2
	echo the orphaned user data and deliberately create a new Android instance. >&2
	exit 1
fi

if ! run_nonprivileged_sanity_checks
then
	exit 1
fi

if [ "$REPAIR_MODE" = true ]
then
	if [ ! -f "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]
	then
		echo "Existing-install repair requires a regular Android image: $WAYDROID_IMAGE" >&2
		exit 1
	fi
	if [ "$AUTO_REPAIR_MODE" = true ]
	then
		echo Existing Android state detected. Selecting safe host-repair mode by default.
	fi
elif [ "$REINSTALL_ANDROID_MODE" = true ] && \
	{ [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ] || \
	  [ -e "$WAYDROID_USER_STATE" ] || [ -L "$WAYDROID_USER_STATE" ] || \
	  [ -e "$WAYDROID_LEGACY_USER_STATE" ] || [ -L "$WAYDROID_LEGACY_USER_STATE" ]; }
then
	if { [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; } && \
		{ [ ! -f "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; }
	then
		echo "Android reinstallation refuses a non-regular image: $WAYDROID_IMAGE" >&2
		exit 1
	fi
	if ! confirm_android_reinstall
	then
		exit 1
	fi
	ANDROID_REINSTALL_HAS_EXISTING=true
fi

if [ ! -f "$DECK_CONFIG_FILE" ]
then
	echo No Deck artifact configuration was found. Using the official public bundle source.
	if ! STEAMOS_WAYDROID_INTERNAL=1 "$ARTIFACT_CONFIGURATOR" --defaults
	then
		echo Artifact configuration was not completed. >&2
		exit 1
	fi
fi
LOGFILE=$WORKING_DIR/logfile
WAYDROID_SCRIPT=https://github.com/casualsnek/waydroid_script.git
WAYDROID_SCRIPT_DIR=$(mktemp -d)/waydroid_script
ARM_Choice=libhoudini
ACTIVE_BUNDLE=$HOME/.local/opt/steamos-waydroid/current
BUNDLED_CAGE=$ACTIVE_BUNDLE/bin/cage
BUNDLED_WLR_RANDR=$ACTIVE_BUNDLE/bin/wlr-randr
BUNDLE_TARGET_CHECK=$ACTIVE_BUNDLE/tools/check-bundle-target.sh
BUNDLE_COMPATIBILITY_REPORT=$ACTIVE_BUNDLE/tools/compatibility-report.sh
BUNDLE_TARGET_ALLOW=$HOME/.local/opt/steamos-waydroid/allow-target-mismatch
HOST_PACKAGE_ROOT=$ACTIVE_BUNDLE/packages

# android TV builds
ANDROID13_TV_OTA=https://ota.supechicken666.dev

echo script version: $SCRIPT_VERSION_SHA
if [ "$REPAIR_MODE" = true ]
then
	echo Mode: repair existing installation
elif [ "$REINSTALL_ANDROID_MODE" = true ]
then
	if [ "$ANDROID_REINSTALL_HAS_EXISTING" = true ]
	then
		echo Mode: reinstall Android while retaining recoverable copies of the previous image and user data
	else
		echo Mode: install Android; no previous persistent image was found
	fi
fi

# Select an already-installed exact target bundle, or fetch the matching
# published artifact, before this installer performs privileged integration.
if ! ensure_sanity_bundle
then
	exit 1
fi

python_package=("$HOST_PACKAGE_ROOT"/python-gbinder*.zst)
if [ "${#python_package[@]}" -ne 1 ] || [ ! -f "${python_package[0]}" ]
then
	echo The target-built bundle must contain exactly one python-gbinder package. >&2
	exit 1
fi
packaged_python_version=$(bsdtar -tf "${python_package[0]}" | \
	awk -F/ '$2 == "lib" && $3 ~ /^python[0-9]+\.[0-9]+$/ {sub(/^python/, "", $3); print $3; exit}')
host_python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if [ -z "$packaged_python_version" ] || [ "$packaged_python_version" != "$host_python_version" ]
then
	echo "Bundled python-gbinder targets Python ${packaged_python_version:-unknown}, but SteamOS provides Python $host_python_version." >&2
	echo Build and publish a compatible bundle before continuing. >&2
	exit 1
fi

# Defence in depth: repeat the active-bundle verification before continuing.
if [ ! -x "$BUNDLED_CAGE" ] || [ ! -x "$BUNDLED_WLR_RANDR" ] || \
	[ ! -x "$BUNDLE_TARGET_CHECK" ] || \
	[ ! -x "$BUNDLE_COMPATIBILITY_REPORT" ] || \
	[ ! -f "$ACTIVE_BUNDLE/.verified" ]
then
	echo Target-built bundle is missing or unverified.
	echo Expected bundle: $ACTIVE_BUNDLE
	echo Run the installer again and inspect the bundle-selection error.
	exit 1
fi
target_check_args=("$ACTIVE_BUNDLE")
active_bundle_version=$(basename "$(readlink -f "$ACTIVE_BUNDLE")")
if [ -r "$BUNDLE_TARGET_ALLOW" ] && \
	[ "$(cat "$BUNDLE_TARGET_ALLOW")" = "$active_bundle_version" ]
then
	target_check_args+=(--allow-target-mismatch)
fi
if ! "$BUNDLE_TARGET_CHECK" "${target_check_args[@]}"
then
	report_file="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid/reports/$(date -u +%Y%m%dT%H%M%SZ)-compatibility.md"
	"$BUNDLE_COMPATIBILITY_REPORT" "$ACTIVE_BUNDLE" "$report_file" || true
	echo The active bundle was built for a different SteamOS target.
	echo Compatibility report: "$report_file"
	echo Build, publish, and install a bundle for the current SteamOS build first.
	exit 1
fi

abort_run () {
	if [ "$REPAIR_MODE" = true ]
	then
		echo Repair failed. Persistent Android data has not been removed. >&2
		exit 1
	fi
	cleanup_exit
}

reinstall_exit_cleanup () {
	exit_status=$?
	trap - EXIT
	if [ "${ANDROID_REINSTALL_COMMITTED:-false}" != true ]
	then
		restore_archived_android_state_after_failure || true
	fi
	restore_decky_loader || true
	return "$exit_status"
}

prompt_return_to_gaming_mode () {
	if zenity --question --text="Do you Want to Return to Gaming Mode?"
	then
		qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
	fi
}

# Return success only when no matching shortcut exists. Existing entries are
# deliberately left to Steam and are never modified or deleted here.
shortcut_should_be_created () {
	shortcut_target=$1
	shortcut_label=$2
	SHORTCUT_MATCH_COUNT=$(python3 "$WORKING_DIR/extras/icon.py" count "$shortcut_target")
	shortcut_status=$?
	if [ "$shortcut_status" -ne 0 ] || ! [[ "$SHORTCUT_MATCH_COUNT" =~ ^[0-9]+$ ]]
	then
		echo "Warning: Steam shortcuts could not be inspected; $shortcut_label will not be changed." >&2
		return 1
	fi
	if [ "$SHORTCUT_MATCH_COUNT" -eq 0 ]
	then
		return 0
	fi

	echo "$SHORTCUT_MATCH_COUNT matching $shortcut_label shortcut(s) already exist; leaving them unchanged."
	return 1
}

wait_for_new_shortcut () {
	shortcut_target=$1
	previous_count=$2
	shortcut_wait_attempt=0
	while [ "$shortcut_wait_attempt" -lt 45 ]
	do
		current_count=$(python3 "$WORKING_DIR/extras/icon.py" count "$shortcut_target" 2> /dev/null) || \
			current_count=""
		if [[ "$current_count" =~ ^[0-9]+$ ]] && [ "$current_count" -gt "$previous_count" ]
		then
			return 0
		fi
		sleep 1
		shortcut_wait_attempt=$((shortcut_wait_attempt + 1))
	done
	return 1
}

ensure_game_mode_shortcuts () {
	echo "Checking Game Mode shortcuts..."
	logged_in_user=$(whoami)
	logged_in_home=$(eval echo "~$logged_in_user")
	launcher_script="${logged_in_home}/Android_Waydroid/Android_Waydroid_Cage.sh"
	if [ -d "${logged_in_home}/Android_Waydroid" ]
	then
		mkdir -p "${logged_in_home}/Android_Waydroid/icons"
		cp "$WORKING_DIR/extras/icon.py" \
			"${logged_in_home}/Android_Waydroid/steam-shortcuts.py"
		cp -a "$WORKING_DIR/extras/icons/." \
			"${logged_in_home}/Android_Waydroid/icons/"
	fi

	if shortcut_should_be_created waydroid Waydroid
	then
		if [ ! -f "$launcher_script" ]
		then
			echo "Error: Launcher script '$launcher_script' not found." >&2
		else
			chmod +x "$launcher_script"
			TMP_DESKTOP="/tmp/waydroid-temp.desktop"
			cat > "$TMP_DESKTOP" << EOF
[Desktop Entry]
Name=Waydroid
Exec=${launcher_script}
Path=${logged_in_home}/Android_Waydroid
Type=Application
Terminal=false
Icon=${logged_in_home}/Android_Waydroid/icons/waydroid/icon.png
EOF
			chmod +x "$TMP_DESKTOP"
			if steamos-add-to-steam "$TMP_DESKTOP"
			then
				if wait_for_new_shortcut waydroid "$SHORTCUT_MATCH_COUNT"
				then
					shortcut_reconcile_args=(
					reconcile waydroid
					--artwork-dir "$WORKING_DIR/extras/icons/waydroid"
					)
					shortcut_reconcile_args+=(--keep-duplicates)
					python3 "$WORKING_DIR/extras/icon.py" "${shortcut_reconcile_args[@]}" || \
						echo "Warning: Waydroid artwork could not be installed." >&2
				else
					echo "Warning: Steam did not create the Waydroid shortcut within 45 seconds." >&2
				fi
			else
				echo "Warning: Waydroid shortcut could not be created." >&2
			fi
			rm -f "$TMP_DESKTOP"
		fi
	fi

	if shortcut_should_be_created nested-desktop "Nested Desktop"
	then
		if steamos-add-to-steam /usr/bin/steamos-nested-desktop &> /dev/null
		then
			if wait_for_new_shortcut nested-desktop "$SHORTCUT_MATCH_COUNT"
			then
				shortcut_reconcile_args=(
				reconcile nested-desktop
				--artwork-dir "$WORKING_DIR/extras/icons/nested-desktop"
				)
				shortcut_reconcile_args+=(--keep-duplicates)
				python3 "$WORKING_DIR/extras/icon.py" "${shortcut_reconcile_args[@]}" || \
					echo "Warning: Nested Desktop artwork could not be installed." >&2
			else
				echo "Warning: Steam did not create the Nested Desktop shortcut within 45 seconds." >&2
			fi
		else
			echo "Warning: Nested Desktop shortcut could not be created." >&2
		fi
	fi
}

# The bundle is present and verified; only now request sudo and stop Decky.
if ! run_privileged_sanity_checks
then
	exit 1
fi
if [ "${DECKY_LOADER_STOPPED:-false}" = true ]
then
	trap restore_decky_loader EXIT
	trap 'exit 130' HUP INT TERM
fi

# sanity checks are all good. lets go!
if [ "$REPAIR_MODE" = true ]
then
	repair_exit_cleanup () {
		trap - EXIT HUP INT TERM
		echo -e "$current_password\n" | sudo -S systemctl stop waydroid-container.service &> /dev/null || true
		unmount_waydroid_var "$WAYDROID_IMAGE"
		echo -e "$current_password\n" | sudo -S steamos-readonly enable &> /dev/null || true
	}
	trap repair_exit_cleanup EXIT
	trap 'exit 130' HUP INT TERM
	# An interrupted prior session must not leave the persistent image busy while
	# packages and root-owned integration are restored.
	echo -e "$current_password\n" | sudo -S systemctl stop waydroid-container.service &> /dev/null || true
	unmount_waydroid_var "$WAYDROID_IMAGE"
	if ! validate_existing_android_image
	then
		echo Repair stopped before changing SteamOS host integration. >&2
		exit 1
	fi
elif [ "$REINSTALL_ANDROID_MODE" = true ] && [ "$ANDROID_REINSTALL_HAS_EXISTING" = true ]
then
	trap reinstall_exit_cleanup EXIT
	trap 'exit 130' HUP INT TERM
	if ! archive_existing_android_state
	then
		echo Android reinstallation stopped before replacing the existing Android state. >&2
		exit 1
	fi
fi

# Android modification tooling is needed only for a new installation.
if [ "$REPAIR_MODE" != true ]
then
	echo Cloning casualsnek / aleasto waydroid_script repo.
	echo This can take a few minutes depending on the speed of the internet connection and if github is having issues.
	echo If the git clone is slow - cancel the script \(CTL-C\) and run it again.

	git clone --depth=1 $WAYDROID_SCRIPT $WAYDROID_SCRIPT_DIR &> /dev/null
	if [ $? -eq 0 ]
	then
		echo Repo has been successfully cloned! Proceed to the next step.
	else
		echo Error cloning the casualsnek / aleasto waydroid_script repo!
		rm -rf $WAYDROID_SCRIPT_DIR
		abort_run
	fi
fi

# unlock the readonly and initialize keyring using the devmode method
echo Unlocking SteamOS and initializing keyring via steamos-devmode. This can take a while.
echo "*** steamos-devmode ***" &> $LOGFILE
echo -e "$current_password\n" | sudo -S steamos-devmode enable --no-prompt &>> $LOGFILE

if [ $? -eq 0 ]
then
	echo pacman keyring has been initialized!
else
	echo Error initializing keyring!
	abort_run
fi

# Install the target-built Waydroid host package set from the verified bundle.
echo Installing waydroid packages. This can take a while.
echo "*** pacman install waydroid packages ***" &>> $LOGFILE
cd $WORKING_DIR
echo -e "$current_password\n" | sudo -S pacman -U --noconfirm \
	"$HOST_PACKAGE_ROOT"/libglibutil*.zst "$HOST_PACKAGE_ROOT"/libgbinder*.zst \
	"$HOST_PACKAGE_ROOT"/python-gbinder*.zst "$HOST_PACKAGE_ROOT"/waydroid*.zst &>> $LOGFILE

if [ $? -eq 0 ]
then
	echo Waydroid has been installed!
	echo -e "$current_password\n" | sudo -S systemctl disable waydroid-container.service
else
	echo Error installing waydroid. Run the script again to install waydroid.
	abort_run
fi

# firewall config for waydroid0 interface to forward packets for internet to work
# but first lets enable firewalld - some instance of SteamOS this is disabled / stopped?
firewalld_was_active=false
if systemctl is-active --quiet firewalld.service
then
	firewalld_was_active=true
fi
echo -e "$current_password\n" | sudo -S systemctl start firewalld
echo -e "$current_password\n" | sudo -S firewall-cmd --zone=trusted --add-interface=waydroid0 &> /dev/null
echo -e "$current_password\n" | sudo -S firewall-cmd --zone=trusted --add-port={53,67}/udp &> /dev/null
echo -e "$current_password\n" | sudo -S firewall-cmd --zone=trusted --add-forward &> /dev/null
if [ "$REPAIR_MODE" = true ]
then
	# Persist only this project's rules. Do not copy unrelated runtime firewall
	# changes into the permanent configuration during a repair.
	echo -e "$current_password\n" | sudo -S firewall-cmd --permanent --zone=trusted --add-interface=waydroid0 &> /dev/null
	echo -e "$current_password\n" | sudo -S firewall-cmd --permanent --zone=trusted --add-port=53/udp &> /dev/null
	echo -e "$current_password\n" | sudo -S firewall-cmd --permanent --zone=trusted --add-port=67/udp &> /dev/null
	echo -e "$current_password\n" | sudo -S firewall-cmd --permanent --zone=trusted --add-forward &> /dev/null
else
	echo -e "$current_password\n" | sudo -S firewall-cmd --runtime-to-permanent &> /dev/null
fi
if [ "$firewalld_was_active" != true ]
then
	echo -e "$current_password\n" | sudo -S systemctl stop firewalld
fi

# Recreate user-side host integration in both fresh-install and repair modes.
# These files live outside the Android image and are safe to refresh.
mkdir -p ~/Android_Waydroid/config &> /dev/null

# waydroid startup and shutdown scripts
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-startup-scripts /usr/bin/waydroid-startup-scripts
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-shutdown-scripts /usr/bin/waydroid-shutdown-scripts
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-mount /usr/bin/waydroid-mount
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-firewall /usr/bin/waydroid-firewall
echo -e "$current_password\n" | sudo -S chmod +x /usr/bin/waydroid-startup-scripts /usr/bin/waydroid-shutdown-scripts /usr/bin/waydroid-mount /usr/bin/waydroid-firewall

# custom sudoers file do not ask for sudo for the custom waydroid scripts
echo -e "$current_password\n" | sudo -S visudo -cf extras/zzzzzzzz-waydroid > /dev/null || abort_run
echo -e "$current_password\n" | sudo -S install -o root -g root -m 0440 \
	extras/zzzzzzzz-waydroid /etc/sudoers.d/zzzzzzzz-waydroid
echo -e "$current_password\n" | sudo -S systemctl daemon-reload

# Copy Waydroid launcher dependencies.
cp extras/scripts/Android_Waydroid_Cage.sh extras/scripts/Waydroid-Toolbox.sh \
	extras/scripts/Waydroid-Updater.sh extras/scripts/select-bundle ~/Android_Waydroid
# Remove the pre-public helper name after installing its neutral replacement.
rm -f ~/Android_Waydroid/select-private-bundle
for config_file in fake_wifi fake_touch
do
	if [ "$REPAIR_MODE" != true ] || [ ! -e "$HOME/Android_Waydroid/config/$config_file" ]
	then
		cp "extras/config/$config_file" ~/Android_Waydroid/config
	fi
done
cp extras/icon.py ~/Android_Waydroid/steam-shortcuts.py
mkdir -p ~/Android_Waydroid/icons
cp -a extras/icons/. ~/Android_Waydroid/icons/

# Waydroid launcher, toolbox and updater.
chmod +x ~/Android_Waydroid/*.sh ~/Android_Waydroid/select-bundle

# Dolphin File Manager extension for root access.
mkdir -p ~/.local/share/kio/servicemenus
cp extras/open_as_root.desktop ~/.local/share/kio/servicemenus
chmod +x ~/.local/share/kio/servicemenus/open_as_root.desktop

# Desktop shortcuts for toolbox + updater.
ln -sfn ~/Android_Waydroid/Waydroid-Toolbox.sh ~/Desktop/Waydroid-Toolbox &> /dev/null
ln -sfn ~/Android_Waydroid/Waydroid-Updater.sh ~/Desktop/Waydroid-Updater &> /dev/null


sudo mkdir -p /var/lib/waydroid
if [ "$REPAIR_MODE" = true ]
then
	echo Mounting the validated Android image read-only for repair verification.
	ROOTDEV=$(sudo losetup --find --show "$WAYDROID_IMAGE")
	if ! sudo mount -o ro,noload "$ROOTDEV" /var/lib/waydroid
	then
		echo Error mounting the existing Android image. >&2
		abort_run
	fi
else
	if [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]
	then
		echo Refusing to initialize Android while an unhandled image exists: "$WAYDROID_IMAGE" >&2
		abort_run
	fi
	echo Preparing a new persistent Android image.
	if ! mount_waydroid_var
	then
		echo Error creating the new Android image. >&2
		abort_run
	fi
fi

if [ "$REPAIR_MODE" = true ]
then
	if [ ! -s /var/lib/waydroid/waydroid_base.prop ]
	then
		echo The persistent image mounted, but waydroid_base.prop is missing. >&2
		echo Repair stopped without initializing or modifying Android. >&2
		abort_run
	fi

	echo Restoring the custom-image integration.
	echo -e "$current_password\n" | sudo -S mkdir -p /etc/waydroid-extra
	if [ -L /etc/waydroid-extra/images ]
	then
		if [ "$(readlink /etc/waydroid-extra/images)" != /var/lib/waydroid/custom ]
		then
			echo /etc/waydroid-extra/images points to an unexpected location. >&2
			echo Repair will not overwrite it. >&2
			abort_run
		fi
	elif [ -e /etc/waydroid-extra/images ]
	then
		echo /etc/waydroid-extra/images exists and is not the expected symlink. >&2
		echo Repair will not overwrite it. >&2
		abort_run
	else
		echo -e "$current_password\n" | sudo -S ln -s /var/lib/waydroid/custom /etc/waydroid-extra/images
	fi

	echo Verifying repaired host integration.
	for required_file in \
		/usr/bin/waydroid \
		/usr/bin/waydroid-startup-scripts \
		/usr/bin/waydroid-shutdown-scripts \
		/usr/bin/waydroid-mount \
		/usr/bin/waydroid-firewall \
		/usr/lib/systemd/system/waydroid-container.service \
		/etc/sudoers.d/zzzzzzzz-waydroid
	do
		if [ ! -e "$required_file" ]
		then
			echo "Repair verification failed: $required_file is missing." >&2
			abort_run
		fi
	done
	if ! python3 -c 'import gbinder' &> /dev/null
	then
		echo Repair verification failed: python-gbinder cannot be imported. >&2
		abort_run
	fi
	if ldd /usr/lib/libgbinder.so.1 2> /dev/null | grep -q 'not found'
	then
		echo Repair verification failed: libgbinder has an unresolved dependency. >&2
		abort_run
	fi
	echo -e "$current_password\n" | sudo -S visudo -cf /etc/sudoers.d/zzzzzzzz-waydroid > /dev/null || abort_run

	echo Unmounting the persistent Android image after verification.
	echo -e "$current_password\n" | sudo -S systemctl stop waydroid-container.service &> /dev/null || true
	unmount_waydroid_var "$WAYDROID_IMAGE"
	echo -e "$current_password\n" | sudo -S steamos-readonly enable
	trap - EXIT HUP INT TERM
	echo Waydroid host integration has been repaired. Android data was not reinitialized or modified.
	ensure_game_mode_shortcuts
	prompt_return_to_gaming_mode
	exit 0
fi

	echo Downloading waydroid image from sourceforge.
	echo This can take a few seconds to a few minutes depending on the internet connection and the speed of the sourceforge mirror.
	echo Sometimes it connects to a slow sourceforge mirror and the downloads are slow -. This is beyond my control!
	echo If the downloads are slow due to a slow sourceforge mirror - cancel the script \(CTL-C\) and run it again.

	# place custom overlay files here - key layout, hosts, audio.rc etc etc
	# copy fixed key layout for Steam Controller
	echo -e "$current_password\n" | sudo -S mkdir -p /var/lib/waydroid/overlay/system/usr/keylayout
	echo -e "$current_password\n" | sudo -S cp extras/fixes/Vendor_28de_Product_11ff.kl /var/lib/waydroid/overlay/system/usr/keylayout/

	# copy custom audio.rc patch to lower the audio latency
	echo -e "$current_password\n" | sudo -S mkdir -p /var/lib/waydroid/overlay/system/etc/init
	echo -e "$current_password\n" | sudo -S cp extras/fixes/audio.rc /var/lib/waydroid/overlay/system/etc/init/

	# download custom hosts file from StevenBlack to block ads (adware + malware + fakenews + gambling + pr0n)
	echo -e "$current_password\n" | sudo -S wget https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts \
		       -O /var/lib/waydroid/overlay/system/etc/hosts

	Android_Choice=$(zenity --width 1040 --height 320 --list --radiolist --multiple \
		--title "SteamOS Waydroid Bundle  - https://github.com/pjohno/steamos-waydroid-bundle"\
		--column "Select One" \
		--column "Option" \
		--column="Description - Read this carefully!"\
		TRUE A13_GAPPS "Download official Android 13 image with Google Play Store."\
		FALSE A13_NO_GAPPS "Download official Android 13 image without Google Play Store."\
		FALSE TV13_GAPPS "Download unofficial Android 13 TV image with Google Play Store - thanks SupeChicken666 for the image!" \
		FALSE TV13_NO_GAPPS "Download unofficial Android 13 TV image without Google Play Store - thanks SupeChicken666 for the image!" \
		FALSE EXIT "***** Exit this script *****")

		if [ $? -eq 1 ] || [ "$Android_Choice" == "EXIT" ]
		then
			echo User pressed CANCEL / EXIT. Goodbye!
			cleanup_exit

		elif [ "$Android_Choice" == "A13_GAPPS" ]
		then
			echo Initializing Waydroid.
			echo -e "$current_password\n" | sudo -S waydroid init -s GAPPS
			check_waydroid_init

		elif [ "$Android_Choice" == "A13_NO_GAPPS" ]
		then
			echo Initializing Waydroid.
			echo -e "$current_password\n" | sudo -S waydroid init
			check_waydroid_init

		elif [ "$Android_Choice" == "TV13_GAPPS" ]
		then
			echo Initializing Waydroid.
 			echo -e "$current_password\n" | sudo -S waydroid init -c ${ANDROID13_TV_OTA}/system -v ${ANDROID13_TV_OTA}/vendor -s GAPPS
			check_waydroid_init

		elif [ "$Android_Choice" == "TV13_NO_GAPPS" ]
		then
			echo Initializing Waydroid.
 			echo -e "$current_password\n" | sudo -S waydroid init -c ${ANDROID13_TV_OTA}/system -v ${ANDROID13_TV_OTA}/vendor
			check_waydroid_init
		fi

	# run casualsnek / aleasto waydroid_script
	echo Install $ARM_Choice widevine and fingerprint spoof.
	if [ "$Android_Choice" == "TV13_GAPPS" ] || [ "$Android_Choice" == "TV13_NO_GAPPS" ]
	then
		echo No need for casualsnek / aleasto waydroid_script for TV13 images.
		echo TV13 images already contains libhoudini arm translation layer and widevine.
	else
		install_android_extras
	fi

	# apply custom config for controller detection, root and fingerprint spoof
	apply_android_custom_config

	# change GPU rendering to use minigbm_gbm_mesa
	echo -e "$current_password\n" | sudo -S sed -i "s/ro.hardware.gralloc=.*/ro.hardware.gralloc=minigbm_gbm_mesa/g" /var/lib/waydroid/waydroid_base.prop

	# all done lets re-enable the readonly
	echo -e "$current_password\n" | sudo -S steamos-readonly enable
	echo Waydroid has been successfully installed!

	# unmount the custom /var/lib/waydroid
	echo Unmounting the custom /var/lib/waydroid
	echo -e "$current_password\n" | sudo systemctl stop waydroid-container.service
	unmount_waydroid_var
	if ! mv extras/waydroid.img ~/Android_Waydroid/waydroid.img
	then
		echo Failed to activate the newly initialized Android image. >&2
		abort_run
	fi
	ANDROID_REINSTALL_COMMITTED=true
	if [ -n "${ARCHIVED_ANDROID_IMAGE:-}" ] && [ -f "$ARCHIVED_ANDROID_IMAGE" ]
	then
		printf 'The previous Android image remains archived at: %s\n' "$ARCHIVED_ANDROID_IMAGE"
	fi
	if [ -n "${ARCHIVED_ANDROID_USER_STATE:-}" ] && \
		{ [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]; }
	then
		printf 'The previous Android user data remains archived at: %s\n' "$ARCHIVED_ANDROID_USER_STATE"
	fi
	if [ -n "${ARCHIVED_ANDROID_LEGACY_USER_STATE:-}" ] && \
		{ [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]; }
	then
		printf 'The previous legacy Android user data remains archived at: %s\n' "$ARCHIVED_ANDROID_LEGACY_USER_STATE"
	fi

ensure_game_mode_shortcuts

# If this run stopped Decky, offer to restart it before possibly ending the
# Desktop Mode session. The EXIT trap remains as a retry after a start failure.
prompt_restore_decky_loader || true

# all done! Display dialog box for Gaming Mode
prompt_return_to_gaming_mode
