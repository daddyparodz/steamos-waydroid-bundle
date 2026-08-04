#!/bin/bash

# define functions here
restore_decky_loader () {
	if [ "${DECKY_LOADER_STOPPED:-false}" = true ]
	then
		echo Re-enabling the Decky Loader plugin service.
		if printf '%s\n' "$current_password" | \
			sudo -S systemctl start plugin_loader.service
		then
			DECKY_LOADER_STOPPED=false
		else
			echo Warning: Decky Loader could not be restarted. >&2
			return 1
		fi
	fi
}

prompt_restore_decky_loader () {
	local prompt_status

	if [ "${DECKY_LOADER_STOPPED:-false}" != true ]
	then
		return 0
	fi

	zenity --question \
		--title "SteamOS Waydroid Installer" \
		--text "Decky Loader was running before installation and was stopped temporarily.\n\nRestart Decky Loader now?" \
		--width 500 --height 75
	prompt_status=$?
	case "$prompt_status" in
		0)
			restore_decky_loader
			;;
		1)
			printf 'Decky Loader will remain stopped at the user\047s request.\n'
			# The EXIT trap restores Decky after failures. Clear ownership here so an
			# explicit choice to leave it stopped is respected on successful exit.
			DECKY_LOADER_STOPPED=false
			;;
		*)
			echo Warning: the Decky Loader restart prompt failed. >&2
			return 1
			;;
	esac
}

confirm_android_reinstall () {
	local confirmation

	cat <<EOF

Existing Android state was found:
EOF
	for existing_path in \
		"$WAYDROID_IMAGE" \
		"$HOME/.local/share/waydroid" \
		"$HOME/waydroid"
	do
		if [ -e "$existing_path" ] || [ -L "$existing_path" ]
		then
			printf '  %s\n' "$existing_path"
		fi
	done
	cat <<EOF

Android reinstallation creates a new Android instance. The current image and
host-side Android user data will be renamed in place instead of deleted. Its
applications, settings and logins will not appear in the new instance, but the
complete previous state will remain available as timestamped archives.
EOF
	IFS= read -r -p "Type REINSTALL ANDROID to continue: " confirmation
	if [ "$confirmation" != "REINSTALL ANDROID" ]
	then
		echo Android reinstallation cancelled.
		return 1
	fi
}

detach_android_image () {
	local image_path=$1 loop_device

	sudo systemctl stop waydroid-container.service 2> /dev/null || true
	if findmnt --mountpoint /var/lib/waydroid > /dev/null 2>&1
	then
		sudo umount /var/lib/waydroid
	fi
	while IFS=: read -r loop_device _
	do
		if [[ "$loop_device" == /dev/loop* ]]
		then
			sudo losetup -d "$loop_device"
		fi
	done < <(sudo losetup -j "$image_path")
}

waydroid_mounts_are_active () {
	findmnt -rn -o TARGET | grep -Eq '^/var/lib/waydroid(/|$)'
}

validate_existing_android_image () {
	local filesystem_type check_mount loop_device validation_failed

	if [ ! -f "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]
	then
		echo "Existing Android image is not a regular file: $WAYDROID_IMAGE" >&2
		return 1
	fi

	detach_android_image "$WAYDROID_IMAGE" || return 1
	filesystem_type=$(sudo blkid -p -s TYPE -o value -- "$WAYDROID_IMAGE" 2> /dev/null || true)
	if [ "$filesystem_type" != ext4 ]
	then
		echo "Existing Android image is not a recognisable ext4 filesystem: $WAYDROID_IMAGE" >&2
		return 1
	fi

	check_mount=$(sudo mktemp -d /run/steamos-waydroid-image-check.XXXXXX) || return 1
	loop_device=$(sudo losetup --find --show "$WAYDROID_IMAGE") || {
		sudo rmdir "$check_mount" 2> /dev/null || true
		return 1
	}
	if ! sudo mount -o ro,noload "$loop_device" "$check_mount"
	then
		sudo losetup -d "$loop_device" 2> /dev/null || true
		sudo rmdir "$check_mount" 2> /dev/null || true
		return 1
	fi

	validation_failed=false
	for required_path in \
		waydroid_base.prop \
		waydroid.cfg \
		lxc/waydroid/config \
		rootfs
	do
		if ! sudo test -e "$check_mount/$required_path"
		then
			echo "Existing Android image is missing: $required_path" >&2
			validation_failed=true
		fi
	done
	if ! sudo test -s "$check_mount/waydroid_base.prop" || \
		! sudo test -s "$check_mount/waydroid.cfg"
	then
		echo Existing Android image has empty Waydroid configuration files. >&2
		validation_failed=true
	fi

	sudo umount "$check_mount" || validation_failed=true
	sudo losetup -d "$loop_device" 2> /dev/null || validation_failed=true
	sudo rmdir "$check_mount" 2> /dev/null || true

	if [ "$validation_failed" = true ]
	then
		echo Existing Android state could not be validated and was not modified. >&2
		return 1
	fi
	printf 'Existing Android image passed read-only structural validation.\n'
}

archive_existing_android_state () {
	local timestamp archive_path source_path

	ANDROID_REINSTALL_ARCHIVE_READY=false
	if [ -f "$WAYDROID_IMAGE" ]
	then
		detach_android_image "$WAYDROID_IMAGE" || return 1
	else
		sudo systemctl stop waydroid-container.service 2> /dev/null || true
	fi
	if waydroid_mounts_are_active
	then
		echo Android reinstallation stopped because a Waydroid mount is still active. >&2
		findmnt -R /var/lib/waydroid >&2 || true
		return 1
	fi

	timestamp=$(date -u +%Y%m%dT%H%M%SZ)
	ANDROID_REINSTALL_TIMESTAMP=$timestamp
	ARCHIVED_ANDROID_IMAGE="$ANDROID_HOME/waydroid.img.pre-reinstall-$timestamp"
	ARCHIVED_ANDROID_USER_STATE="$HOME/.local/share/waydroid.pre-reinstall-$timestamp"
	ARCHIVED_ANDROID_LEGACY_USER_STATE="$HOME/waydroid.pre-reinstall-$timestamp"
	FAILED_ANDROID_IMAGE="$ANDROID_HOME/waydroid.img.failed-reinstall-$timestamp"
	FAILED_ANDROID_USER_STATE="$HOME/.local/share/waydroid.failed-reinstall-$timestamp"
	FAILED_ANDROID_LEGACY_USER_STATE="$HOME/waydroid.failed-reinstall-$timestamp"

	for archive_path in \
		"$ARCHIVED_ANDROID_IMAGE" \
		"$ARCHIVED_ANDROID_USER_STATE" \
		"$ARCHIVED_ANDROID_LEGACY_USER_STATE" \
		"$FAILED_ANDROID_IMAGE" \
		"$FAILED_ANDROID_USER_STATE" \
		"$FAILED_ANDROID_LEGACY_USER_STATE"
	do
		if [ -e "$archive_path" ] || [ -L "$archive_path" ]
		then
			echo "Refusing to overwrite an existing Android state path: $archive_path" >&2
			return 1
		fi
	done

	if [ -f "$WAYDROID_IMAGE" ]
	then
		if ! sudo mv -- "$WAYDROID_IMAGE" "$ARCHIVED_ANDROID_IMAGE"
		then
			return 1
		fi
	fi
	for source_path in "$HOME/.local/share/waydroid" "$HOME/waydroid"
	do
		if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]
		then
			continue
		fi
		if [ "$source_path" = "$HOME/.local/share/waydroid" ]
		then
			archive_path=$ARCHIVED_ANDROID_USER_STATE
		else
			archive_path=$ARCHIVED_ANDROID_LEGACY_USER_STATE
		fi
		if ! sudo mv -- "$source_path" "$archive_path"
		then
			restore_archived_android_state_after_failure
			return 1
		fi
	done
	ANDROID_REINSTALL_ARCHIVE_READY=true

	if [ -f "$ARCHIVED_ANDROID_IMAGE" ]
	then
		printf 'Previous Android image archived at: %s\n' "$ARCHIVED_ANDROID_IMAGE"
	fi
	if [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]
	then
		printf 'Previous Android user data archived at: %s\n' "$ARCHIVED_ANDROID_USER_STATE"
	fi
	if [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]
	then
		printf 'Previous legacy Android user data archived at: %s\n' "$ARCHIVED_ANDROID_LEGACY_USER_STATE"
	fi
}

move_failed_android_state_aside () {
	local source_path=$1 failed_path=$2

	if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]
	then
		return 0
	fi
	if [ -e "$failed_path" ] || [ -L "$failed_path" ]
	then
		echo "Cannot move failed replacement state aside; destination exists: $failed_path" >&2
		return 1
	fi
	sudo mv -- "$source_path" "$failed_path"
	printf 'Incomplete replacement state retained at: %s\n' "$failed_path"
}

restore_archived_android_state_after_failure () {
	local restore_failed=false image_path loop_device

	[ -n "${ARCHIVED_ANDROID_IMAGE:-}" ] || return 0
	[ "${ANDROID_REINSTALL_COMMITTED:-false}" != true ] || return 0

	printf 'Restoring the complete previous Android state after installation failure.\n'
	if [ "${ANDROID_REINSTALL_ARCHIVE_READY:-false}" != true ]
	then
		if [ -f "$ARCHIVED_ANDROID_IMAGE" ] && [ ! -e "$WAYDROID_IMAGE" ]
		then
			sudo mv -- "$ARCHIVED_ANDROID_IMAGE" "$WAYDROID_IMAGE" || restore_failed=true
		fi
		if { [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]; } && \
			[ ! -e "$HOME/.local/share/waydroid" ] && [ ! -L "$HOME/.local/share/waydroid" ]
		then
			sudo mv -- "$ARCHIVED_ANDROID_USER_STATE" "$HOME/.local/share/waydroid" || restore_failed=true
		fi
		if { [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]; } && \
			[ ! -e "$HOME/waydroid" ] && [ ! -L "$HOME/waydroid" ]
		then
			sudo mv -- "$ARCHIVED_ANDROID_LEGACY_USER_STATE" "$HOME/waydroid" || restore_failed=true
		fi
		[ "$restore_failed" = false ] || return 1
		ARCHIVED_ANDROID_IMAGE=""
		ARCHIVED_ANDROID_USER_STATE=""
		ARCHIVED_ANDROID_LEGACY_USER_STATE=""
		return 0
	fi

	sudo systemctl stop waydroid-container.service 2> /dev/null || true
	if findmnt --mountpoint /var/lib/waydroid > /dev/null 2>&1
	then
		sudo umount /var/lib/waydroid || restore_failed=true
	fi
	if waydroid_mounts_are_active
	then
		echo Cannot restore previous Android state while Waydroid mounts remain active. >&2
		return 1
	fi
	for image_path in "$WAYDROID_IMAGE" "${WORKING_DIR:-}/extras/waydroid.img"
	do
		[ -n "$image_path" ] && [ -f "$image_path" ] || continue
		while IFS=: read -r loop_device _
		do
			if [[ "$loop_device" == /dev/loop* ]]
			then
				sudo losetup -d "$loop_device" || restore_failed=true
			fi
		done < <(sudo losetup -j "$image_path")
	done

	if ! move_failed_android_state_aside "$WAYDROID_IMAGE" "$FAILED_ANDROID_IMAGE"
	then
		restore_failed=true
	fi
	if ! move_failed_android_state_aside "$HOME/.local/share/waydroid" "$FAILED_ANDROID_USER_STATE"
	then
		restore_failed=true
	fi
	if ! move_failed_android_state_aside "$HOME/waydroid" "$FAILED_ANDROID_LEGACY_USER_STATE"
	then
		restore_failed=true
	fi
	if [ "$restore_failed" = true ]
	then
		echo Previous Android archives were left untouched because replacement state could not be moved safely. >&2
		return 1
	fi

	mkdir -p -- "$ANDROID_HOME" "$HOME/.local/share"
	if [ -f "$ARCHIVED_ANDROID_IMAGE" ]
	then
		sudo mv -- "$ARCHIVED_ANDROID_IMAGE" "$WAYDROID_IMAGE" || restore_failed=true
	fi
	if [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]
	then
		sudo mv -- "$ARCHIVED_ANDROID_USER_STATE" "$HOME/.local/share/waydroid" || restore_failed=true
	fi
	if [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]
	then
		sudo mv -- "$ARCHIVED_ANDROID_LEGACY_USER_STATE" "$HOME/waydroid" || restore_failed=true
	fi
	if [ "$restore_failed" = true ]
	then
		echo Automatic restoration was incomplete; inspect the timestamped archives before retrying. >&2
		return 1
	fi

	ARCHIVED_ANDROID_IMAGE=""
	ARCHIVED_ANDROID_USER_STATE=""
	ARCHIVED_ANDROID_LEGACY_USER_STATE=""
	printf 'Previous Android image and user data were restored.\n'
}

mount_waydroid_var () {
	# this will initialize and configure custom /var/lib/waydroid
	# first make sure /var/lib/waydroid is not mounted
	echo -e "$current_password\n" | sudo -S umount /var/lib/waydroid &> /dev/null
	echo -e "$current_password\n" | sudo -S losetup -d $(losetup | grep waydroid.img | cut -d " " -f1)  &> /dev/null
	
	# prepare the custom /var/lib/waydroid
	gunzip -k -f extras/waydroid.img.gz && \
		mkfs.ext4 -F extras/waydroid.img && \
		ROOTDEV=$(sudo losetup --find --show extras/waydroid.img) && \
		echo -e "$current_password\n" | sudo -S mount $ROOTDEV /var/lib/waydroid
}

unmount_waydroid_var () {
	# this will unmount the custom /var/lib/waydroid
	echo -e "$current_password\n" | sudo -S umount /var/lib/waydroid &> /dev/null
	local image_path="${1:-}"
	local loop_device
	if [ -n "$image_path" ] && [ -f "$image_path" ]
	then
		while IFS=: read -r loop_device _
		do
			if [[ "$loop_device" == /dev/loop* ]]
			then
				echo -e "$current_password\n" | sudo -S losetup -d "$loop_device" &> /dev/null || true
			fi
		done < <(echo -e "$current_password\n" | sudo -S losetup -j "$image_path" 2> /dev/null)
	else
		echo -e "$current_password\n" | sudo -S losetup -d $(losetup | grep waydroid.img | cut -d " " -f1)  &> /dev/null
	fi
}

cleanup_exit () {
	# Call this function to clean up after a host-installation failure.
	
	echo Something went wrong! Performing cleanup. Run the script again to install waydroid.
	
	# remove installed packages
	echo -e "$current_password\n" | sudo -S pacman -R --noconfirm libglibutil libgbinder \
		python-gbinder waydroid &> /dev/null
	
	# unmount the custom /var/lib/waydroid
	echo -e "$current_password\n" | sudo -S umount /var/lib/waydroid &> /dev/null
	echo -e "$current_password\n" | sudo -S losetup -d $(losetup | grep waydroid.img | cut -d " " -f1)  &> /dev/null

	# delete the waydroid directories
	echo -e "$current_password\n" | sudo -S rm -rf /var/lib/waydroid &> /dev/null
	
	# delete waydroid config and scripts
	echo -e "$current_password\n" | sudo -S rm /etc/sudoers.d/zzzzzzzz-waydroid /usr/bin/waydroid* &> /dev/null

	# delete Waydroid Toolbox and Waydroid Update symlinks
	rm ~/Desktop/Waydroid-Updater &> /dev/null
	rm ~/Desktop/Waydroid-Toolbox &> /dev/null

	# delete Android_Waydroid folder and enable the readonly
	echo -e "$current_password\n" | sudo -S rm -rf ~/Android_Waydroid/*.sh ~/Android_Waydroid/config &> /dev/null
	echo -e "$current_password\n" | sudo -S steamos-readonly enable &> /dev/null
	
	# Re-enable Decky if this installer stopped it during preflight.
	restore_decky_loader || true
	restore_archived_android_state_after_failure || true
	
	echo Cleanup completed. Please open an issue on the GitHub repo or leave a comment on the YT channel - 10MinuteSteamDeckGamer.
	exit 1
}

# apply custom config for controller detection, root and fingerprint spoof
apply_android_custom_config () {

	# waydroid_base.prop - controller config and disable root
	echo "" | sudo tee -a /var/lib/waydroid/waydroid_base.prop > /dev/null
	cat extras/props/waydroid_base.prop | sudo tee -a /var/lib/waydroid/waydroid_base.prop > /dev/null

	# waydroid_base.prop fingerprint spoof - check if A11 or A13 and apply the spoof accordingly
	if [ "$Android_Choice" == "A13_NO_GAPPS" ] || [ "$Android_Choice" == "A13_GAPPS" ]
	then
		echo "" | sudo tee -a /var/lib/waydroid/waydroid_base.prop > /dev/null
		cat extras/props/android_spoof.prop | sudo tee -a /var/lib/waydroid/waydroid_base.prop > /dev/null

	else [ "$Android_Choice" == "TV13_NO_GAPPS" ] || [ "$Android_Choce" == "TV13_GAPPS" ]
		echo TV13.
		echo "" | sudo tee -a /var/lib/waydroid/waydroid_base.prop > /dev/null
		cat extras/props/androidtv_spoof.prop | sudo tee -a /var/lib/waydroid/waydroid_base.prop
	fi
}

# install arm translation layer from casualsnek / aleasto waydroid_script
install_android_extras () {

	# casualsnek / aleasto waydroid_script - install libndk / libhoudini and widevine
	python3 -m venv $WAYDROID_SCRIPT_DIR/venv
	$WAYDROID_SCRIPT_DIR/venv/bin/pip install -r $WAYDROID_SCRIPT_DIR/requirements.txt &> /dev/null

	echo "$ARM_Choice installation started:"
	echo -e "$current_password\n" | sudo -S $WAYDROID_SCRIPT_DIR/venv/bin/python3 $WAYDROID_SCRIPT_DIR/main.py -a13 install {$ARM_Choice,widevine}

	echo casualsnek / aleasto waydroid_script done. $ARM_Choice installed.
	echo -e "$current_password\n" | sudo -S rm -rf $WAYDROID_SCRIPT_DIR
}

check_waydroid_init () {
	# check if waydroid initialization completed without errors
	if [ $? -eq 0 ]
	then
		echo Waydroid initialization completed without errors!

	else
		echo Waydroid did not initialize correctly.
		echo This could be a hash mismatch / corrupted download.
		echo This could also be a python issue. Attach this screenshot when filing a bug report!
		echo Output of whereis python - $(whereis python)
		echo Output of which python - $(which python)
		echo Output of python version - $(python -V)

		cleanup_exit
	fi
}
