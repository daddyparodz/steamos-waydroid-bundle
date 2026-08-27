#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/deck-home"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_LOG="$TEST_ROOT/commands.log"
mkdir -p "$TEST_HOME" "$MOCK_BIN"

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

cat >"$MOCK_BIN/getent" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == passwd && ${2:-} == testuser ]] || exit 1
printf 'testuser:x:1000:1000:Test User:%s:/bin/bash\n' "$TEST_HOME"
EOF
chmod +x "$MOCK_BIN/getent"
export PATH="$MOCK_BIN:/usr/bin:/bin"
export TEST_HOME MOCK_LOG

# shellcheck source=../libexec/steamos-waydroid/waydroid-profile.sh
source "$REPO_ROOT/libexec/steamos-waydroid/waydroid-profile.sh"

assert_profile() {
	local requested_profile=$1 expected_profile=$2 expected_image=$3
	local expected_xdg=$4 expected_state=$5 expected_data=$6

	HOME=$TEST_HOME resolve_waydroid_profile "$requested_profile"
	[[ "$WAYDROID_PROFILE" == "$expected_profile" ]] || fail "wrong profile: $WAYDROID_PROFILE"
	[[ "$WAYDROID_IMAGE" == "$expected_image" ]] || fail "wrong image: $WAYDROID_IMAGE"
	[[ "$WAYDROID_XDG_DATA_HOME" == "$expected_xdg" ]] || fail "wrong XDG data home"
	[[ "$WAYDROID_USER_STATE" == "$expected_state" ]] || fail "wrong user state"
	[[ "$WAYDROID_DATA" == "$expected_data" ]] || fail "wrong data path"
}

HOME=$TEST_HOME resolve_waydroid_profile
[[ "$WAYDROID_PROFILE" == main ]] || fail 'no profile did not default to main'

WAYDROID_IMAGE=/untrusted/image WAYDROID_DATA=/untrusted/data \
	HOME=$TEST_HOME resolve_waydroid_profile main
[[ "$WAYDROID_IMAGE" == "$TEST_HOME/Android_Waydroid/waydroid.img" ]] ||
	fail 'resolver trusted an image path from the environment'
[[ "$WAYDROID_DATA" == "$TEST_HOME/.local/share/waydroid/data" ]] ||
	fail 'resolver trusted a data path from the environment'

assert_profile main main \
	"$TEST_HOME/Android_Waydroid/waydroid.img" \
	"$TEST_HOME/.local/share" \
	"$TEST_HOME/.local/share/waydroid" \
	"$TEST_HOME/.local/share/waydroid/data"
assert_profile test test \
	"$TEST_HOME/Android_Waydroid/test/waydroid.img" \
	"$TEST_HOME/.local/share/waydroid-test" \
	"$TEST_HOME/.local/share/waydroid-test/waydroid" \
	"$TEST_HOME/.local/share/waydroid-test/waydroid/data"

if HOME=$TEST_HOME resolve_waydroid_profile custom 2>"$TEST_ROOT/invalid.log"; then
	fail 'invalid profile was accepted'
fi
grep -Fq 'unsupported Waydroid profile: custom' "$TEST_ROOT/invalid.log" ||
	fail 'invalid profile failure was unclear'

HOME=/root SUDO_USER=testuser resolve_waydroid_profile main
[[ "$WAYDROID_IMAGE" == "$TEST_HOME/Android_Waydroid/waydroid.img" ]] ||
	fail 'root main profile used root home'
HOME=/root SUDO_USER=testuser resolve_waydroid_profile test
[[ "$WAYDROID_IMAGE" == "$TEST_HOME/Android_Waydroid/test/waydroid.img" ]] ||
	fail 'root test profile used root home'
unset SUDO_USER

run_mount_case() (
	local profile=${1:-}
	export HOME=$TEST_HOME
	: >"$MOCK_LOG"
	# shellcheck source=../extras/scripts/waydroid-mount
	source "$REPO_ROOT/extras/scripts/waydroid-mount"
	validate_binder() { :; }
	validate_image() { :; }
	validate_mounted_image() { :; }
	systemctl() {
		[[ ${1:-} != is-active ]]
	}
	findmnt() { return 1; }
	umount() { :; }
	mkdir() { :; }
	mount() {
		printf 'mount' >>"$MOCK_LOG"
		printf ' %s' "$@" >>"$MOCK_LOG"
		printf '\n' >>"$MOCK_LOG"
	}
	losetup() {
		printf 'losetup' >>"$MOCK_LOG"
		printf ' %s' "$@" >>"$MOCK_LOG"
		printf '\n' >>"$MOCK_LOG"
		if [[ ${1:-} == --find ]]; then
			printf '/dev/loop99\n'
		fi
	}
	if [[ -n "$profile" ]]; then
		waydroid_mount_main "$profile"
	else
		waydroid_mount_main
	fi
	printf '%s\n' "$IMAGE" >"$TEST_ROOT/mount-image"
)

run_mount_case
[[ "$(<"$TEST_ROOT/mount-image")" == "$TEST_HOME/Android_Waydroid/waydroid.img" ]] ||
	fail 'default mount did not select main image'
run_mount_case main
grep -Fq "losetup -j $TEST_HOME/Android_Waydroid/waydroid.img" "$MOCK_LOG" ||
	fail 'main mount did not inspect the main image loop device'
run_mount_case test
grep -Fq "losetup -j $TEST_HOME/Android_Waydroid/test/waydroid.img" "$MOCK_LOG" ||
	fail 'test mount did not inspect the test image loop device'

if (
	export HOME=$TEST_HOME
	# shellcheck source=../extras/scripts/waydroid-mount
	source "$REPO_ROOT/extras/scripts/waydroid-mount"
	resolve_waydroid_profile test
	IMAGE=$WAYDROID_IMAGE
	validate_image
) 2>"$TEST_ROOT/missing-test-image.log"; then
	fail 'missing test image unexpectedly passed mount validation'
fi
grep -Fq "Android image is missing or is not a regular file: $TEST_HOME/Android_Waydroid/test/waydroid.img" \
	"$TEST_ROOT/missing-test-image.log" || fail 'missing test image failure was unclear'

mkdir -p "$TEST_HOME/Android_Waydroid/test"
: >"$TEST_HOME/Android_Waydroid/waydroid.img"
: >"$TEST_HOME/Android_Waydroid/test/waydroid.img"
if (
	export HOME=$TEST_HOME
	# shellcheck source=../extras/scripts/waydroid-mount
	source "$REPO_ROOT/extras/scripts/waydroid-mount"
	resolve_waydroid_profile test
	IMAGE=$WAYDROID_IMAGE
	findmnt() {
		if [[ ${3:-} == SOURCE ]]; then
			printf '/dev/loop7\n'
		else
			return 0
		fi
	}
	losetup() {
		printf '%s\n' "$TEST_HOME/Android_Waydroid/waydroid.img"
	}
	validate_runtime_profile
) 2>"$TEST_ROOT/profile-conflict.log"; then
	fail 'test profile accepted an active main image'
fi
grep -Fq 'another Waydroid profile is active' "$TEST_ROOT/profile-conflict.log" ||
	fail 'active profile conflict was unclear'

run_shutdown_case() (
	local profile=$1
	export HOME=$TEST_HOME
	: >"$MOCK_LOG"
	# shellcheck source=../extras/scripts/waydroid-shutdown-scripts
	source "$REPO_ROOT/extras/scripts/waydroid-shutdown-scripts"
	systemctl() { :; }
	findmnt() { return 1; }
	umount() { :; }
	unmount_waydroid_share() { printf 'share-profile %s\n' "$2" >>"$MOCK_LOG"; }
	losetup() {
		printf 'losetup' >>"$MOCK_LOG"
		printf ' %s' "$@" >>"$MOCK_LOG"
		printf '\n' >>"$MOCK_LOG"
	}
	waydroid_shutdown_main "$profile"
)

run_shutdown_case main
grep -Fq "losetup -j $TEST_HOME/Android_Waydroid/waydroid.img" "$MOCK_LOG" ||
	fail 'main shutdown did not inspect the main image loop device'
grep -Fq 'share-profile main' "$MOCK_LOG" || fail 'main shutdown used the wrong share profile'
run_shutdown_case test
grep -Fq "losetup -j $TEST_HOME/Android_Waydroid/test/waydroid.img" "$MOCK_LOG" ||
	fail 'test shutdown did not inspect the test image loop device'
grep -Fq 'share-profile test' "$MOCK_LOG" || fail 'test shutdown used the wrong share profile'

grep -Fq 'REQUESTED_PROFILE=main' "$REPO_ROOT/extras/scripts/Android_Waydroid_Cage.sh" ||
	fail 'launcher no longer defaults to main'
grep -Fq 'export XDG_DATA_HOME=$WAYDROID_XDG_DATA_HOME' \
	"$REPO_ROOT/extras/scripts/Android_Waydroid_Cage.sh" ||
	fail 'launcher does not export the selected XDG data home'
grep -Fq 'sudo /usr/bin/waydroid-mount "$WAYDROID_PROFILE"' \
	"$REPO_ROOT/extras/scripts/Android_Waydroid_Cage.sh" ||
	fail 'launcher does not pass its profile to the privileged mount helper'

printf 'ok - Waydroid profile resolution and privileged runtime selection\n'
