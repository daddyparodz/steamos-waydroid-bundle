#!/bin/bash

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

REPAIR_MODE=false
REPAIR_SHORTCUTS=false
CONFIGURE_ARTIFACTS=false
UNINSTALL_MODE=false
FULL_UNINSTALL_MODE=false
PRIMARY_MODE_COUNT=0
usage () {
	echo "usage: $0 [--repair [--repair-shortcuts] | --configure-artifacts | --uninstall | --uninstall-all]" >&2
}
if [ "$#" -gt 2 ]
then
	usage
	exit 1
fi
for argument in "$@"
do
	case "$argument" in
		--repair)
			REPAIR_MODE=true
			PRIMARY_MODE_COUNT=$((PRIMARY_MODE_COUNT + 1))
			;;
		--repair-shortcuts) REPAIR_SHORTCUTS=true ;;
		--configure-artifacts)
			CONFIGURE_ARTIFACTS=true
			PRIMARY_MODE_COUNT=$((PRIMARY_MODE_COUNT + 1))
			;;
		--uninstall)
			UNINSTALL_MODE=true
			PRIMARY_MODE_COUNT=$((PRIMARY_MODE_COUNT + 1))
			;;
		--uninstall-all)
			FULL_UNINSTALL_MODE=true
			PRIMARY_MODE_COUNT=$((PRIMARY_MODE_COUNT + 1))
			;;
		*)
			usage
			exit 1
			;;
	esac
done
if [ "$PRIMARY_MODE_COUNT" -gt 1 ] || \
	{ [ "$REPAIR_SHORTCUTS" = true ] && [ "$REPAIR_MODE" != true ]; }
then
	usage
	exit 1
fi

clear

echo SteamOS Waydroid Installer - target-built public bundle edition
echo https://github.com/pjohno/steamos-waydroid-personal
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
	SCRIPT_VERSION_SHA=personal
fi
STEAMOS_VERSION=$(cat /etc/os-release | grep -i version_id | cut -d "=" -f2 | cut -d "." -f1-2)
BASE_VERSION=3.8
STEAMOS_BRANCH=$(steamos-select-branch -c)
WORKING_DIR=$SCRIPT_DIR
DECK_CONFIG_FILE=${DECK_CONFIG_FILE:-$WORKING_DIR/.deck-config.env}
DECK_RUNTIME=$WORKING_DIR/libexec/steamos-waydroid
ARTIFACT_CONFIGURATOR=$DECK_RUNTIME/configure-artifacts.sh
if [ "$FULL_UNINSTALL_MODE" = true ]
then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$WORKING_DIR/reset-personal-install.sh" --full-process
	exit $?
elif [ "$UNINSTALL_MODE" = true ]
then
	STEAMOS_WAYDROID_INTERNAL=1 "$WORKING_DIR/reset-personal-install.sh"
	exit $?
elif [ "$CONFIGURE_ARTIFACTS" = true ]
then
	if ! STEAMOS_WAYDROID_INTERNAL=1 "$ARTIFACT_CONFIGURATOR" --force
	then
		echo Artifact configuration was not completed. >&2
		exit 1
	fi
	exit 0
elif [ ! -f "$DECK_CONFIG_FILE" ]
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
FREE_HOME=$(df /home --output=avail | tail -n1)
ARM_Choice=libhoudini
PRIVATE_BUNDLE=$HOME/.local/opt/steamos-waydroid/current
PRIVATE_CAGE=$PRIVATE_BUNDLE/bin/cage
PRIVATE_WLR_RANDR=$PRIVATE_BUNDLE/bin/wlr-randr
PRIVATE_TARGET_CHECK=$PRIVATE_BUNDLE/tools/check-bundle-target.sh
PRIVATE_COMPATIBILITY_REPORT=$PRIVATE_BUNDLE/tools/compatibility-report.sh
PRIVATE_TARGET_ALLOW=$HOME/.local/opt/steamos-waydroid/allow-target-mismatch
HOST_PACKAGE_ROOT=$PRIVATE_BUNDLE/packages
WAYDROID_IMAGE=$HOME/Android_Waydroid/waydroid.img

# android TV builds
ANDROID13_TV_OTA=https://ota.supechicken666.dev

# custom Android 13 builds
ANDROID13_IMG=https://github.com/ryanrudolfoba/SteamOS-Waydroid-Installer/releases/download/Android13-PvZ2/lineage-20-20251210-UNOFFICIAL-10MinuteSteamDeckGamer-Waydroid.zip

# custom Android 13 hash
ANDROID13_IMG_HASH=aafdd4ef69e8a11d64ba02e881c1697d6a3ee4fa4c1fb97e33abc6da5f4bb6d4

echo script version: $SCRIPT_VERSION_SHA
if [ "$REPAIR_MODE" = true ]
then
	echo Mode: repair existing installation
	if [ ! -f "$WAYDROID_IMAGE" ]
	then
		echo "Repair requires an existing Android image: $WAYDROID_IMAGE" >&2
		echo Run the installer without --repair for a new installation. >&2
		exit 1
	fi
	if [ ! -r "$HOME/Android_Waydroid/Android_Waydroid_Cage.sh" ] || \
		[ ! -r "$HOME/Android_Waydroid/config/fake_wifi" ] || \
		[ ! -r "$HOME/Android_Waydroid/config/fake_touch" ]
	then
		echo The persistent Waydroid launcher or configuration is missing. >&2
		echo Repair stopped without changing Android data. >&2
		exit 1
	fi
fi

# Select an already-installed exact target bundle, or fetch the matching
# published artifact, before this installer performs privileged integration.
if ! STEAMOS_WAYDROID_INTERNAL=1 "$DECK_RUNTIME/ensure-private-bundle-on-deck.sh"
then
	echo Unable to install or activate a target-built bundle for this SteamOS target.
	echo Check .deck-config.env and its artifact source, then run the installer again.
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
	echo "Private python-gbinder targets Python ${packaged_python_version:-unknown}, but SteamOS provides Python $host_python_version." >&2
	echo Build and publish a compatible bundle before continuing. >&2
	exit 1
fi

# Defence in depth: repeat the active-bundle verification before continuing.
if [ ! -x "$PRIVATE_CAGE" ] || [ ! -x "$PRIVATE_WLR_RANDR" ] || \
	[ ! -x "$PRIVATE_TARGET_CHECK" ] || \
	[ ! -x "$PRIVATE_COMPATIBILITY_REPORT" ] || \
	[ ! -f "$PRIVATE_BUNDLE/.verified" ]
then
	echo Target-built bundle is missing or unverified.
	echo Expected bundle: $PRIVATE_BUNDLE
	echo Run the installer again and inspect the bundle-selection error.
	exit 1
fi
target_check_args=("$PRIVATE_BUNDLE")
active_bundle_version=$(basename "$(readlink -f "$PRIVATE_BUNDLE")")
if [ -r "$PRIVATE_TARGET_ALLOW" ] && \
	[ "$(cat "$PRIVATE_TARGET_ALLOW")" = "$active_bundle_version" ]
then
	target_check_args+=(--allow-target-mismatch)
fi
if ! "$PRIVATE_TARGET_CHECK" "${target_check_args[@]}"
then
	report_file="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid/reports/$(date -u +%Y%m%dT%H%M%SZ)-compatibility.md"
	"$PRIVATE_COMPATIBILITY_REPORT" "$PRIVATE_BUNDLE" "$report_file" || true
	echo The active bundle was built for a different SteamOS target.
	echo Compatibility report: "$report_file"
	echo Build, publish, and install a bundle for the current SteamOS build first.
	exit 1
fi

# define functions here
source functions.sh

abort_run () {
	if [ "$REPAIR_MODE" = true ]
	then
		echo Repair failed. Persistent Android data has not been removed. >&2
		exit 1
	fi
	cleanup_exit
}

prompt_return_to_gaming_mode () {
	if zenity --question --text="Do you Want to Return to Gaming Mode?"
	then
		qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
	fi
}

# Return success when a new shortcut should be created. When matching entries
# exist, the user can add another, replace all matches, or leave them alone.
shortcut_should_be_created () {
	shortcut_target=$1
	shortcut_label=$2
	SHORTCUT_KEEP_DUPLICATES=false
	python3 "$WORKING_DIR/extras/icon.py" has "$shortcut_target"
	shortcut_status=$?
	case "$shortcut_status" in
		0) ;;
		1) return 0 ;;
		*)
			echo "Warning: Steam shortcuts could not be inspected; $shortcut_label will not be changed." >&2
			return 1
			;;
	esac

	echo
	echo "Matching $shortcut_label Steam shortcut(s):"
	python3 "$WORKING_DIR/extras/icon.py" describe "$shortcut_target"
	shortcut_choice=$(zenity --list --radiolist \
		--title="SteamOS Waydroid Installer" \
		--text="Choose what to do with the matching $shortcut_label shortcut(s). Details are shown in Konsole." \
		--column="Select" \
		--column="Action" \
		--column="Description" \
		FALSE "Add new shortcut" "Keep all existing shortcuts and add another" \
		TRUE "Delete/Replace" "Remove all matches and create one new shortcut" \
		FALSE "Do nothing" "Leave shortcuts and artwork unchanged" \
		--width=760 --height=300) || shortcut_choice="Do nothing"

	case "$shortcut_choice" in
		"Add new shortcut")
			echo "Existing $shortcut_label shortcut(s) will be kept and another will be added."
			SHORTCUT_KEEP_DUPLICATES=true
			return 0
			;;
		"Delete/Replace")
			if ! python3 "$WORKING_DIR/extras/icon.py" remove "$shortcut_target"
			then
				echo "Warning: $shortcut_label could not be removed; it will not be recreated." >&2
				return 1
			fi
			return 0
			;;
		"Do nothing"|"")
			echo "$shortcut_label shortcut and artwork were left unchanged."
			return 1
			;;
		*)
			echo "Warning: unknown shortcut action; $shortcut_label was left unchanged." >&2
			return 1
			;;
	esac
}

repair_game_mode_shortcuts () {
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
				sleep 3
				shortcut_reconcile_args=(
					reconcile waydroid
					--artwork-dir "$WORKING_DIR/extras/icons/waydroid"
				)
				if [ "$SHORTCUT_KEEP_DUPLICATES" = true ]
				then
					shortcut_reconcile_args+=(--keep-duplicates)
				fi
				python3 "$WORKING_DIR/extras/icon.py" "${shortcut_reconcile_args[@]}" || \
					echo "Warning: Waydroid artwork could not be installed." >&2
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
			sleep 3
			shortcut_reconcile_args=(
				reconcile nested-desktop
				--artwork-dir "$WORKING_DIR/extras/icons/nested-desktop"
			)
			if [ "$SHORTCUT_KEEP_DUPLICATES" = true ]
			then
				shortcut_reconcile_args+=(--keep-duplicates)
			fi
			python3 "$WORKING_DIR/extras/icon.py" "${shortcut_reconcile_args[@]}" || \
				echo "Warning: Nested Desktop artwork could not be installed." >&2
		else
			echo "Warning: Nested Desktop shortcut could not be created." >&2
		fi
	fi
}

# run the sanity checks
source sanity-checks.sh

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

# lets install the custom config files
if [ "$REPAIR_MODE" != true ]
then
	mkdir -p ~/Android_Waydroid/config &> /dev/null
fi

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

if [ "$REPAIR_MODE" != true ]
then
	# copy waydroid launcher dependencies
	cp extras/scripts/Android_Waydroid_Cage.sh extras/scripts/Waydroid-Toolbox.sh \
		extras/scripts/Waydroid-Updater.sh extras/scripts/select-private-bundle ~/Android_Waydroid
	cp extras/config/fake_wifi extras/config/fake_touch ~/Android_Waydroid/config
	cp extras/icon.py ~/Android_Waydroid/steam-shortcuts.py
	mkdir -p ~/Android_Waydroid/icons
	cp -a extras/icons/. ~/Android_Waydroid/icons/

	# waydroid launcher, toolbox and updater
	chmod +x ~/Android_Waydroid/*.sh ~/Android_Waydroid/select-private-bundle

	# Dolphin File Manager extension for root access
	mkdir -p ~/.local/share/kio/servicemenus
	cp extras/open_as_root.desktop ~/.local/share/kio/servicemenus
	chmod +x ~/.local/share/kio/servicemenus/open_as_root.desktop

	# desktop shortcuts for toolbox + updater
	ln -s ~/Android_Waydroid/Waydroid-Toolbox.sh ~/Desktop/Waydroid-Toolbox &> /dev/null
	ln -s ~/Android_Waydroid/Waydroid-Updater.sh ~/Desktop/Waydroid-Updater &> /dev/null
fi


# lets check if this is a reinstall
echo Checking if this is a reinstall - step1.
if [ -d /var/lib/waydroid ]
then
	echo /var/lib/waydroid exists! 
else
	sudo -S mkdir /var/lib/waydroid
fi

echo Checking if this is a reinstall - step2.
if [ -f $HOME/Android_Waydroid/waydroid.img ]
then
	echo Most probably this is a reinstall!
	echo Mounting waydroid.img to /var/lib/waydroid
	ROOTDEV=$(sudo losetup --find --show "$WAYDROID_IMAGE")
	if [ "$REPAIR_MODE" = true ]
	then
		# Repair only validates persistent state; do not replay the ext4 journal or
		# write to Android data while restoring the SteamOS host integration.
		sudo mount -o ro,noload "$ROOTDEV" /var/lib/waydroid
	else
		sudo mount "$ROOTDEV" /var/lib/waydroid
	fi

	if [ $? -eq 0 ]
	then
		echo waydroid.img successfully mounted to /var/lib/waydroid
	else
		echo Error mounting waydroid.img
		echo Exiting immediately.
		abort_run
	fi

else
	echo waydroid.img not found!
	echo Preparing to mount waydroid.img
	mount_waydroid_var

	if [ $? -eq 0 ]
	then
		echo Custom /var/lib/waydroid has been created and mounted!
	else
		echo Error creating /var/lib/waydroid. Exiting immediately.
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
	if [ "$REPAIR_SHORTCUTS" = true ]
	then
		repair_game_mode_shortcuts
	fi
	prompt_return_to_gaming_mode
	exit 0
fi

echo Checking if this is a reinstall - step3.
grep blazer /var/lib/waydroid/waydroid_base.prop &> /dev/null || grep PH7M_EU_5596 /var/lib/waydroid/waydroid_base.prop &> /dev/null
if [ $? -eq 0 ]
then
	echo This seems to be a reinstall. Lets just make sure the symlinks are in place!
	if [ ! -d /etc/waydroid-extra ]
	then
		echo -e "$current_password\n" | sudo -S mkdir /etc/waydroid-extra
		echo -e "$current_password\n" | sudo -S ln -s /var/lib/waydroid/custom /etc/waydroid-extra/images &> /dev/null
	fi

	# all done lets re-enable the readonly
	echo -e "$current_password\n" | sudo -S steamos-readonly enable
	echo Waydroid has been successfully installed!
else
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
		--title "SteamOS Waydroid Installer  - https://github.com/ryanrudolfoba/SteamOS-Waydroid-Installer"\
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
	mv extras/waydroid.img ~/Android_Waydroid/waydroid.img
fi

repair_game_mode_shortcuts

# all done! Display dialog box for Gaming Mode
prompt_return_to_gaming_mode
