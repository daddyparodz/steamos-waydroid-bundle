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

set_android_image_selection A14_NO_GAPPS
[[ $ANDROID_VERSION == 14 && $ANDROID_VARIANT == VANILLA ]] ||
	fail 'Android 14 Vanilla selection metadata is wrong'
[[ $ANDROID_IMAGE_PACKAGING == combined ]] ||
	fail 'Android 14 packaging is not marked combined'
[[ $ANDROID_COMBINED_URL == *'/images/non-atv-images/lineage-21.0-20260125-UNOFFICIAL-waydroid_x86_64.zip' ]] ||
	fail 'Android 14 did not select the published non-ATV x86_64 archive'
[[ $ANDROID_COMBINED_URL != *waydroid_tv* && $ANDROID_COMBINED_URL != *WayDroidATV* ]] ||
	fail 'Android 14 selected a TV image'

if set_android_image_selection A14_GAPPS 2>"$TEST_ROOT/a14-gapps.log"; then
	fail 'an unavailable Android 14 GApps artifact was invented'
fi
grep -Fq 'unsupported Android image selection: A14_GAPPS' "$TEST_ROOT/a14-gapps.log" ||
	fail 'unavailable Android 14 GApps selection did not fail clearly'

if set_android_image_selection A15_GAPPS 2>"$TEST_ROOT/a15-gapps.log"; then
	fail 'an unavailable Android 15 GApps artifact was invented'
fi
grep -Fq 'unsupported Android image selection: A15_GAPPS' "$TEST_ROOT/a15-gapps.log" ||
	fail 'unavailable Android 15 GApps selection did not fail clearly'

set_android_image_selection A15_NO_GAPPS
[[ $ANDROID_VERSION == 15 && $ANDROID_VARIANT == VANILLA ]] ||
	fail 'Android 15 Vanilla selection metadata is wrong'
[[ $ANDROID_IMAGE_PACKAGING == combined ]] ||
	fail 'Android 15 packaging is not marked combined'
[[ $ANDROID_COMBINED_URL == *'/images/non-atv-images/lineage-22.2-20260224-UNOFFICIAL-waydroid_x86_64.zip' ]] ||
	fail 'Android 15 did not select the published non-ATV x86_64 archive'
[[ $ANDROID_COMBINED_URL != *waydroid_tv* && $ANDROID_COMBINED_URL != *WayDroidATV* ]] ||
	fail 'Android 15 selected a TV image'

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

run_mock_install A14_NO_GAPPS || fail 'mocked Android 14 install failed'
[[ $(grep -c '^download ' "$TEST_ROOT/A14_NO_GAPPS.log") == 1 ]] ||
	fail 'Android 14 did not download exactly one combined archive'
[[ $(grep -c '^extract .*combined.zip ' "$TEST_ROOT/A14_NO_GAPPS.log") == 2 ]] ||
	fail 'Android 14 did not extract system and vendor from its combined archive'
grep -Fq 'init waydroid init -f' "$TEST_ROOT/A14_NO_GAPPS.log" ||
	fail 'Android 14 did not initialize from installed custom images'

run_mock_install A15_NO_GAPPS || fail 'mocked Android 15 install failed'
[[ $(grep -c '^download ' "$TEST_ROOT/A15_NO_GAPPS.log") == 1 ]] ||
	fail 'Android 15 did not download exactly one combined archive'
[[ $(grep -c '^extract .*combined.zip ' "$TEST_ROOT/A15_NO_GAPPS.log") == 2 ]] ||
	fail 'Android 15 did not extract system and vendor from its combined archive'
grep -Fq 'init waydroid init -f' "$TEST_ROOT/A15_NO_GAPPS.log" ||
	fail 'Android 15 did not initialize from installed custom images'

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

run_mock_failure A14_NO_GAPPS "$ANDROID14_COMBINED_URL" ||
	fail 'Android 14 download failure did not stop cleanly without fallback'
run_mock_failure A15_NO_GAPPS "$ANDROID15_COMBINED_URL" ||
	fail 'Android 15 download failure did not stop cleanly without fallback'
run_mock_failure A16_NO_GAPPS "$ANDROID16_VANILLA_SYSTEM_URL" ||
	fail 'Android 16 download failure did not stop cleanly without fallback'

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
grep -Fq '"Android 14 — Vanilla (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android 14 Vanilla'
grep -Fq '"Android 15 — Vanilla (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android 15 Vanilla'
grep -Fq '"Android 16 — GApps (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android 16 GApps'
grep -Fq '"Android 16 — Vanilla (Experimental)"' "$INSTALLER" ||
	fail 'test installer does not offer Android 16 Vanilla'
[[ $(grep -Fc '"Android 14 — Vanilla (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android 14 must appear only in the test-image chooser'
[[ $(grep -Fc '"Android 15 — Vanilla (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android 15 must appear only in the test-image chooser'
[[ $(grep -Fc '"Android 16 — GApps (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android 16 GApps must appear only in the test-image chooser'
[[ $(grep -Fc '"Android 16 — Vanilla (Experimental)"' "$INSTALLER") == 1 ]] ||
	fail 'Android 16 Vanilla must appear only in the test-image chooser'

printf 'ok - Android 13/14/15/16 test image selection, packaging, failures, and metadata\n'
