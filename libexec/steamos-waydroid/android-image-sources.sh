#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Sourced API variables are supplied/consumed by the installer.

# Experimental, regular (non-ATV) x86_64 images published by the
# SupeChicken / WayDroid-ATV project. Keep all externally hosted image
# artifacts here so installer control flow does not acquire release URLs.
SUPECHICKEN_SOURCEFORGE_BASE=https://downloads.sourceforge.net/project/waydroid-atv/images

# LineageOS 23.2 / Android 16 QPR2. System and vendor are separate archives;
# the same vendor image is used by the GApps and Vanilla system variants.
ANDROID16_GAPPS_SYSTEM_URL=$SUPECHICKEN_SOURCEFORGE_BASE/system/waydroid_x86_64/lineage-23.2-20260717-GAPPS-waydroid_x86_64-system.zip
ANDROID16_VANILLA_SYSTEM_URL=$SUPECHICKEN_SOURCEFORGE_BASE/system/waydroid_x86_64/lineage-23.2-20260717-VANILLA-waydroid_x86_64-system.zip
ANDROID16_VENDOR_URL=$SUPECHICKEN_SOURCEFORGE_BASE/vendor/waydroid_x86_64/lineage-23.2-20260717-MAINLINE-waydroid_x86_64-vendor.zip

# LineageOS 23.0 / Android TV 16 QPR0. The TV system and vendor images are a
# matched release and must not be mixed with the regular Android 16 QPR2 set.
ANDROID16_TV_GAPPS_SYSTEM_URL=$SUPECHICKEN_SOURCEFORGE_BASE/system/waydroid_tv_x86_64/lineage-23.0-20260403-GAPPS-waydroid_tv_x86_64-system.zip
ANDROID16_TV_VANILLA_SYSTEM_URL=$SUPECHICKEN_SOURCEFORGE_BASE/system/waydroid_tv_x86_64/lineage-23.0-20260403-VANILLA-waydroid_tv_x86_64-system.zip
ANDROID16_TV_VENDOR_URL=$SUPECHICKEN_SOURCEFORGE_BASE/vendor/waydroid_tv_x86_64/lineage-23.0-20260403-MAINLINE-waydroid_tv_x86_64-vendor.zip

# HeliBoard provides a consistent touch- and mouse-capable keyboard in both the
# regular Android and Android TV images. The TV Leanback keyboard in particular
# does not accept touchscreen or mouse-as-touch activation in Waydroid.
HELIBOARD_VERSION=4.1
HELIBOARD_APK_URL=https://github.com/Helium314/HeliBoard/releases/download/v4.1/HeliBoard_4.1-release.apk
HELIBOARD_APK_SHA256=eb9c06685ebd5b7307491da9ef15fb5e29694077a934a8699b9b6772c6f76075
ANDROID_PLATFORM_TOOLS_VERSION=37.0.1
ANDROID_PLATFORM_TOOLS_URL=https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip
ANDROID_PLATFORM_TOOLS_SHA256=d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1

download_touch_keyboard() {
	local destination=$1 temporary=${1}.part

	rm -f -- "$temporary"
	if ! wget --progress=bar:force:noscroll --tries=3 --timeout=30 \
		-O "$temporary" "$HELIBOARD_APK_URL"; then
		printf 'error: HeliBoard %s download failed\n' "$HELIBOARD_VERSION" >&2
		rm -f -- "$temporary"
		return 1
	fi
	if ! printf '%s  %s\n' "$HELIBOARD_APK_SHA256" "$temporary" | sha256sum -c -; then
		printf 'error: HeliBoard APK checksum verification failed\n' >&2
		rm -f -- "$temporary"
		return 1
	fi
	mv -f -- "$temporary" "$destination"
}

download_android_platform_tools() {
	local destination=$1 archive=${1}.zip.part staging=${1}.staging

	rm -f -- "$archive"
	rm -rf -- "$staging"
	if ! wget --progress=bar:force:noscroll --tries=3 --timeout=30 \
		-O "$archive" "$ANDROID_PLATFORM_TOOLS_URL"; then
		printf 'error: Android platform-tools %s download failed\n' \
			"$ANDROID_PLATFORM_TOOLS_VERSION" >&2
		return 1
	fi
	if ! printf '%s  %s\n' "$ANDROID_PLATFORM_TOOLS_SHA256" "$archive" | sha256sum -c -; then
		printf 'error: Android platform-tools checksum verification failed\n' >&2
		rm -f -- "$archive"
		return 1
	fi
	mkdir -p -- "$staging" || return 1
	if ! bsdtar -xf "$archive" -C "$staging"; then
		printf 'error: could not extract Android platform-tools\n' >&2
		rm -f -- "$archive"
		rm -rf -- "$staging"
		return 1
	fi
	if [ ! -x "$staging/platform-tools/adb" ]; then
		printf 'error: Android platform-tools archive did not contain adb\n' >&2
		rm -f -- "$archive"
		rm -rf -- "$staging"
		return 1
	fi
	rm -rf -- "$destination"
	mv -- "$staging/platform-tools" "$destination"
	rm -rf -- "$staging"
	rm -f -- "$archive"
}

set_android_image_selection() {
	local choice=$1

	ANDROID_VERSION=
	ANDROID_VARIANT=
	ANDROID_IMAGE_PACKAGING=official
	ANDROID_SYSTEM_URL=
	ANDROID_VENDOR_URL=

	case "$choice" in
	A13_GAPPS)
		ANDROID_VERSION=13
		ANDROID_VARIANT=GAPPS
		;;
	A13_NO_GAPPS)
		ANDROID_VERSION=13
		ANDROID_VARIANT=VANILLA
		;;
	TV13_GAPPS)
		ANDROID_VERSION=13
		ANDROID_VARIANT=GAPPS
		ANDROID_IMAGE_PACKAGING=official-ota
		;;
	TV13_NO_GAPPS)
		ANDROID_VERSION=13
		ANDROID_VARIANT=VANILLA
		ANDROID_IMAGE_PACKAGING=official-ota
		;;
	A16_GAPPS)
		ANDROID_VERSION=16
		ANDROID_VARIANT=GAPPS
		ANDROID_IMAGE_PACKAGING=separate
		ANDROID_SYSTEM_URL=$ANDROID16_GAPPS_SYSTEM_URL
		ANDROID_VENDOR_URL=$ANDROID16_VENDOR_URL
		;;
	A16_NO_GAPPS)
		ANDROID_VERSION=16
		ANDROID_VARIANT=VANILLA
		ANDROID_IMAGE_PACKAGING=separate
		ANDROID_SYSTEM_URL=$ANDROID16_VANILLA_SYSTEM_URL
		ANDROID_VENDOR_URL=$ANDROID16_VENDOR_URL
		;;
	TV16_GAPPS)
		ANDROID_VERSION=16
		ANDROID_VARIANT=GAPPS
		ANDROID_IMAGE_PACKAGING=separate
		ANDROID_SYSTEM_URL=$ANDROID16_TV_GAPPS_SYSTEM_URL
		ANDROID_VENDOR_URL=$ANDROID16_TV_VENDOR_URL
		;;
	TV16_NO_GAPPS)
		ANDROID_VERSION=16
		ANDROID_VARIANT=VANILLA
		ANDROID_IMAGE_PACKAGING=separate
		ANDROID_SYSTEM_URL=$ANDROID16_TV_VANILLA_SYSTEM_URL
		ANDROID_VENDOR_URL=$ANDROID16_TV_VENDOR_URL
		;;
	*)
		printf 'error: unsupported Android image selection: %s\n' "$choice" >&2
		return 2
		;;
	esac
}

download_android_image() {
	local source_url=$1 destination=$2

	printf 'Downloading experimental Android image from:\n  %s\n' "$source_url"
	if ! wget --progress=bar:force:noscroll --tries=3 --timeout=30 \
		-O "$destination" "$source_url"; then
		printf 'error: Android image download failed: %s\n' "$source_url" >&2
		return 1
	fi
	[[ -s "$destination" ]] || {
		printf 'error: Android image download was empty: %s\n' "$source_url" >&2
		return 1
	}
}

extract_android_image() {
	local archive=$1 destination=$2 component=$3
	local image_name=${component}.img

	mkdir -p -- "$destination" || return 1
	if ! bsdtar -xf "$archive" -C "$destination" "$image_name"; then
		printf 'error: could not extract %s from Android image archive: %s\n' \
			"$image_name" "$archive" >&2
		return 1
	fi
	if [[ ! -s "$destination/$image_name" || -L "$destination/$image_name" ]]; then
		printf 'error: Android image archive did not provide a safe %s: %s\n' \
			"$image_name" "$archive" >&2
		return 1
	fi
}

ensure_waydroid_custom_image_path() {
	printf '%s\n' "$current_password" |
		sudo -S mkdir -p /var/lib/waydroid/custom /etc/waydroid-extra || return 1
	if [[ -L /etc/waydroid-extra/images ]]; then
		if [[ $(readlink /etc/waydroid-extra/images) != /var/lib/waydroid/custom ]]; then
			printf 'error: /etc/waydroid-extra/images points to an unexpected location\n' >&2
			return 1
		fi
	elif [[ -e /etc/waydroid-extra/images ]]; then
		printf 'error: /etc/waydroid-extra/images exists and is not the expected symlink\n' >&2
		return 1
	else
		printf '%s\n' "$current_password" |
			sudo -S ln -s /var/lib/waydroid/custom /etc/waydroid-extra/images || return 1
	fi
}

install_system_vendor_images() {
	local system_image=$1 vendor_image=$2

	ensure_waydroid_custom_image_path || return 1
	printf '%s\n' "$current_password" |
		sudo -S install -m 0644 "$system_image" /var/lib/waydroid/custom/system.img || return 1
	printf '%s\n' "$current_password" |
		sudo -S install -m 0644 "$vendor_image" /var/lib/waydroid/custom/vendor.img
}

install_experimental_android_image() {
	local download_dir system_archive vendor_archive
	local extracted_dir

	[[ ${ANDROID_IMAGE_PACKAGING:-} == separate ]] || {
		printf 'error: no experimental Android image was selected\n' >&2
		return 2
	}

	mkdir -p -- "$WAYDROID_XDG_DATA_HOME" || return 1
	download_dir=$(mktemp -d "$WAYDROID_XDG_DATA_HOME/.image-download.XXXXXX") || return 1
	extracted_dir=$download_dir/extracted

	system_archive=$download_dir/system.zip
	vendor_archive=$download_dir/vendor.zip
	download_android_image "$ANDROID_SYSTEM_URL" "$system_archive" &&
		download_android_image "$ANDROID_VENDOR_URL" "$vendor_archive" &&
		extract_android_image "$system_archive" "$extracted_dir" system &&
		extract_android_image "$vendor_archive" "$extracted_dir" vendor || {
		rm -rf -- "$download_dir"
		return 1
	}

	if ! install_system_vendor_images \
		"$extracted_dir/system.img" "$extracted_dir/vendor.img"; then
		rm -rf -- "$download_dir"
		return 1
	fi
	rm -rf -- "$download_dir"

	printf 'Initializing Waydroid from the installed Android %s %s images.\n' \
		"$ANDROID_VERSION" "$ANDROID_VARIANT"
	printf '%s\n' "$current_password" | run_profile_sudo waydroid init -f
}

record_test_android_metadata() {
	[[ ${WAYDROID_PROFILE:-} == test ]] || {
		printf 'error: refusing to write test metadata outside the test profile\n' >&2
		return 1
	}
	[[ $ANDROID_VERSION =~ ^(13|16)$ ]] || return 1
	[[ $ANDROID_VARIANT == GAPPS || $ANDROID_VARIANT == VANILLA ]] || return 1

	mkdir -p -- "${WAYDROID_IMAGE%/*}" || return 1
	printf '%s\n' "$ANDROID_VERSION" >"${WAYDROID_IMAGE%/*}/android-version" || return 1
	printf '%s\n' "$ANDROID_VARIANT" >"${WAYDROID_IMAGE%/*}/android-variant"
}
