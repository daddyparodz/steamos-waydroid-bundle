#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2209 # Variables are consumed by sourced installer helpers.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

# shellcheck source=../libexec/steamos-waydroid/android-image-sources.sh
source "$REPO_ROOT/libexec/steamos-waydroid/android-image-sources.sh"

set_android_image_selection A13_GAPPS
[[ $ANDROID_VERSION == 13 && $ANDROID_VARIANT == GAPPS ]] ||
	fail 'Android 13 GApps selection metadata changed'
[[ $ANDROID_IMAGE_PACKAGING == official ]] ||
	fail 'Android 13 no longer uses the official initialization path'

set_android_image_selection A13_NO_GAPPS
[[ $ANDROID_VERSION == 13 && $ANDROID_VARIANT == VANILLA ]] ||
	fail 'Android 13 Vanilla selection metadata changed'
[[ $ANDROID_IMAGE_PACKAGING == official ]] ||
	fail 'Android 13 Vanilla no longer uses the official initialization path'

for removed_choice in A14_GAPPS A14_NO_GAPPS A15_GAPPS A15_NO_GAPPS; do
	if set_android_image_selection "$removed_choice" 2>"$TEST_ROOT/$removed_choice.log"; then
		fail "$removed_choice remains selectable"
	fi
	grep -Fq "unsupported Android image selection: $removed_choice" \
		"$TEST_ROOT/$removed_choice.log" ||
		fail "$removed_choice did not fail clearly"
done

set_android_image_selection A16_GAPPS
[[ $ANDROID_VERSION == 16 && $ANDROID_VARIANT == GAPPS ]] ||
	fail 'Android 16 GApps selection metadata is wrong'
[[ $ANDROID_IMAGE_PACKAGING == separate ]] ||
	fail 'Android 16 packaging is not marked separate'
[[ $ANDROID_SYSTEM_URL == *'-GAPPS-waydroid_x86_64-system.zip' ]] ||
	fail 'Android 16 GApps did not select its GApps system artifact'
[[ $ANDROID_VENDOR_URL == *'-MAINLINE-waydroid_x86_64-vendor.zip' ]] ||
	fail 'Android 16 did not select its separate vendor artifact'

set_android_image_selection A16_NO_GAPPS
[[ $ANDROID_VERSION == 16 && $ANDROID_VARIANT == VANILLA ]] ||
	fail 'Android 16 Vanilla selection metadata is wrong'
[[ $ANDROID_SYSTEM_URL == *'-VANILLA-waydroid_x86_64-system.zip' ]] ||
	fail 'Android 16 Vanilla did not select its Vanilla system artifact'
[[ $ANDROID_SYSTEM_URL != *waydroid_tv* && $ANDROID_VENDOR_URL != *waydroid_tv* ]] ||
	fail 'Android 16 selected a TV image'

set_android_image_selection TV16_GAPPS
[[ $ANDROID_VERSION == 16 && $ANDROID_VARIANT == GAPPS ]] ||
	fail 'Android TV 16 GApps selection metadata is wrong'
[[ $ANDROID_IMAGE_PACKAGING == separate ]] ||
	fail 'Android TV 16 packaging is not marked separate'
[[ $ANDROID_SYSTEM_URL == *'/system/waydroid_tv_x86_64/lineage-23.0-20260403-GAPPS-waydroid_tv_x86_64-system.zip' ]] ||
	fail 'Android TV 16 GApps did not select its TV system artifact'
[[ $ANDROID_VENDOR_URL == *'/vendor/waydroid_tv_x86_64/lineage-23.0-20260403-MAINLINE-waydroid_tv_x86_64-vendor.zip' ]] ||
	fail 'Android TV 16 did not select its matched TV vendor artifact'

set_android_image_selection TV16_NO_GAPPS
[[ $ANDROID_VERSION == 16 && $ANDROID_VARIANT == VANILLA ]] ||
	fail 'Android TV 16 Vanilla selection metadata is wrong'
[[ $ANDROID_SYSTEM_URL == *'/system/waydroid_tv_x86_64/lineage-23.0-20260403-VANILLA-waydroid_tv_x86_64-system.zip' ]] ||
	fail 'Android TV 16 Vanilla did not select its TV system artifact'
[[ $ANDROID_VENDOR_URL == *waydroid_tv_x86_64* ]] ||
	fail 'Android TV 16 Vanilla selected a regular vendor image'

run_mock_install() (
	local choice=$1
	set_android_image_selection "$choice"
	WAYDROID_XDG_DATA_HOME=$TEST_ROOT/data-$choice
	current_password=test
	MOCK_LOG=$TEST_ROOT/$choice.log
	: >"$MOCK_LOG"

	download_android_image() {
		printf 'download %s %s\n' "$1" "$2" >>"$MOCK_LOG"
		printf 'mock archive\n' >"$2"
	}
	extract_android_image() {
		printf 'extract %s %s\n' "$1" "$3" >>"$MOCK_LOG"
		mkdir -p -- "$2"
		printf 'mock %s image\n' "$3" >"$2/$3.img"
	}
	install_system_vendor_images() {
		[[ -s $1 && -s $2 ]] || return 1
		printf 'install %s %s\n' "$1" "$2" >>"$MOCK_LOG"
	}
	run_profile_sudo() {
		printf 'init' >>"$MOCK_LOG"
		printf ' %s' "$@" >>"$MOCK_LOG"
		printf '\n' >>"$MOCK_LOG"
	}

	install_experimental_android_image
	if compgen -G "$WAYDROID_XDG_DATA_HOME/.image-download.*" >/dev/null; then
		return 1
	fi
)

run_mock_install A16_GAPPS || fail 'mocked Android 16 GApps install failed'
[[ $(grep -c '^download ' "$TEST_ROOT/A16_GAPPS.log") == 2 ]] ||
	fail 'Android 16 did not download separate system and vendor archives'
grep -Fq -- '-GAPPS-waydroid_x86_64-system.zip' "$TEST_ROOT/A16_GAPPS.log" ||
	fail 'Android 16 GApps pipeline used the wrong system artifact'
grep -Fq 'init waydroid init -f' "$TEST_ROOT/A16_GAPPS.log" ||
	fail 'Android 16 GApps did not initialize from installed custom images'

run_mock_install A16_NO_GAPPS || fail 'mocked Android 16 Vanilla install failed'
grep -Fq -- '-VANILLA-waydroid_x86_64-system.zip' "$TEST_ROOT/A16_NO_GAPPS.log" ||
	fail 'Android 16 Vanilla pipeline used the wrong system artifact'

run_mock_install TV16_GAPPS || fail 'mocked Android TV 16 GApps install failed'
[[ $(grep -c '^download ' "$TEST_ROOT/TV16_GAPPS.log") == 2 ]] ||
	fail 'Android TV 16 did not download separate system and vendor archives'
grep -Fq -- '-GAPPS-waydroid_tv_x86_64-system.zip' "$TEST_ROOT/TV16_GAPPS.log" ||
	fail 'Android TV 16 GApps pipeline used the wrong system artifact'
grep -Fq -- '-MAINLINE-waydroid_tv_x86_64-vendor.zip' "$TEST_ROOT/TV16_GAPPS.log" ||
	fail 'Android TV 16 GApps pipeline used the wrong vendor artifact'
grep -Fq 'init waydroid init -f' "$TEST_ROOT/TV16_GAPPS.log" ||
	fail 'Android TV 16 GApps did not initialize from installed custom images'

run_mock_install TV16_NO_GAPPS || fail 'mocked Android TV 16 Vanilla install failed'
grep -Fq -- '-VANILLA-waydroid_tv_x86_64-system.zip' "$TEST_ROOT/TV16_NO_GAPPS.log" ||
	fail 'Android TV 16 Vanilla pipeline used the wrong system artifact'

# A failed experimental download must stop before extraction/init and must not
# invoke any official Android 13 path as a fallback.
run_mock_failure() (
	local choice=$1 expected_url=$2
	set_android_image_selection "$choice"
	WAYDROID_XDG_DATA_HOME=$TEST_ROOT/failing-data-$choice
	current_password=test
	FAIL_LOG=$TEST_ROOT/download-failure-$choice.log
	: >"$FAIL_LOG"
	download_android_image() {
		printf 'failed %s\n' "$1" >>"$FAIL_LOG"
		return 1
	}
	extract_android_image() { printf 'unexpected extract\n' >>"$FAIL_LOG"; }
	install_system_vendor_images() { printf 'unexpected install\n' >>"$FAIL_LOG"; }
	run_profile_sudo() { printf 'unexpected init %s\n' "$*" >>"$FAIL_LOG"; }
	if install_experimental_android_image; then
		exit 1
	fi
	grep -Fq "$expected_url" "$FAIL_LOG"
	! grep -Eq 'unexpected|A13' "$FAIL_LOG"
	! compgen -G "$WAYDROID_XDG_DATA_HOME/.image-download.*" >/dev/null
)

run_mock_failure A16_NO_GAPPS "$ANDROID16_VANILLA_SYSTEM_URL" ||
	fail 'Android 16 download failure did not stop cleanly without fallback'
run_mock_failure TV16_NO_GAPPS "$ANDROID16_TV_VANILLA_SYSTEM_URL" ||
	fail 'Android TV 16 download failure did not stop cleanly without fallback'

# Test metadata remains beside the one test image and cannot touch main state.
TEST_HOME=$TEST_ROOT/home
mkdir -p "$TEST_HOME/Android_Waydroid/test" "$TEST_HOME/.local/share/waydroid-test"
printf 'main image sentinel\n' >"$TEST_HOME/Android_Waydroid/waydroid.img"
printf 'main data sentinel\n' >"$TEST_HOME/main-data"
MAIN_IMAGE_HASH=$(sha256sum "$TEST_HOME/Android_Waydroid/waydroid.img")
MAIN_DATA_HASH=$(sha256sum "$TEST_HOME/main-data")
WAYDROID_PROFILE=test
WAYDROID_IMAGE=$TEST_HOME/Android_Waydroid/test/waydroid.img
ANDROID_VERSION=16
ANDROID_VARIANT=VANILLA
record_test_android_metadata || fail 'test Android metadata was not recorded'
[[ $(<"$TEST_HOME/Android_Waydroid/test/android-version") == 16 ]] ||
	fail 'test Android version metadata is wrong'
[[ $(<"$TEST_HOME/Android_Waydroid/test/android-variant") == VANILLA ]] ||
	fail 'test Android variant metadata is wrong'
[[ $(sha256sum "$TEST_HOME/Android_Waydroid/waydroid.img") == "$MAIN_IMAGE_HASH" ]] ||
	fail 'metadata recording changed the main image'
[[ $(sha256sum "$TEST_HOME/main-data") == "$MAIN_DATA_HASH" ]] ||
	fail 'metadata recording changed main user data'

INSTALLER=$REPO_ROOT/steamos-waydroid-installer.sh
grep -Fq 'TRUE A13_GAPPS "Download official Android 13 image with Google Play Store."' "$INSTALLER" ||
	fail 'main Android 13 GApps choice changed'
grep -Fq 'FALSE A13_NO_GAPPS "Download official Android 13 image without Google Play Store."' "$INSTALLER" ||
	fail 'main Android 13 Vanilla choice changed'
grep -Fq 'run_profile_sudo waydroid init -s GAPPS' "$INSTALLER" ||
	fail 'Android 13 GApps no longer uses the official Waydroid init path'
grep -Fq 'run_profile_sudo waydroid init' "$INSTALLER" ||
	fail 'Android 13 Vanilla no longer uses the official Waydroid init path'
! grep -Eq 'A14_|A15_|Android 14|Android 15' "$INSTALLER" ||
	fail 'test installer still offers Android 14 or Android 15'
grep -Fq '"Android 16 — GApps (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android 16 GApps'
grep -Fq '"Android 16 — Vanilla (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android 16 Vanilla'
grep -Fq '"Android TV 16 — GApps (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android TV 16 GApps'
grep -Fq '"Android TV 16 — Vanilla (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android TV 16 Vanilla'
[[ $(grep -Fc '"Android 16 — GApps (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android 16 GApps must appear only in the test-image chooser'
[[ $(grep -Fc '"Android 16 — Vanilla (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android 16 Vanilla must appear only in the test-image chooser'
[[ $(grep -Fc '"Android TV 16 — GApps (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android TV 16 GApps must appear only in the test-image chooser'
[[ $(grep -Fc '"Android TV 16 — Vanilla (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android TV 16 Vanilla must appear only in the test-image chooser'

printf 'ok - Android 13/16 regular and TV test image selection, packaging, failures, and metadata\n'
