#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

setup_case() {
	local name=$1

	CASE_ROOT="$TEST_ROOT/$name"
	CASE_HOME="$CASE_ROOT/home"
	MOCK_BIN="$CASE_ROOT/bin"
	MOCK_LOG="$CASE_ROOT/commands.log"
	mkdir -p "$CASE_HOME" "$MOCK_BIN"
	: >"$MOCK_LOG"

	cat >"$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	cat >"$MOCK_BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	cat >"$MOCK_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	cat >"$MOCK_BIN/losetup" <<'EOF'
#!/usr/bin/env bash
if [[ ${MOCK_LOOP_ATTACHED:-false} == true ]]; then
	printf '/dev/loop7: []: (%s)\n' "${2:-unknown}"
fi
EOF
	cat >"$MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo' >>"$MOCK_LOG"
printf ' %s' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
[[ ${1:-} != -v ]] || exit 0
"$@"
EOF
	cat >"$MOCK_BIN/steamos-add-to-steam" <<'EOF'
#!/usr/bin/env bash
printf 'STEAM TOOL CALLED\n' >>"$MOCK_LOG"
exit 99
EOF
	cat >"$MOCK_BIN/python3" <<'EOF'
#!/usr/bin/env bash
printf 'PYTHON TOOL CALLED %s\n' "$*" >>"$MOCK_LOG"
exit 99
EOF
	chmod +x "$MOCK_BIN"/*
}

run_remove() {
	local confirmation=${1-}
	set +e
	printf '%s\n' "$confirmation" |
		env -u SUDO_USER \
			HOME="$CASE_HOME" \
			PATH="$MOCK_BIN:/usr/bin:/bin" \
			MOCK_LOG="$MOCK_LOG" \
			MOCK_LOOP_ATTACHED="${MOCK_LOOP_ATTACHED:-false}" \
			"$REPO_ROOT/steamos-waydroid-installer.sh" --remove-test \
			>"$CASE_ROOT/output" 2>&1
	RUN_STATUS=$?
	set -e
}

create_main_state() {
	mkdir -p "$CASE_HOME/Android_Waydroid" "$CASE_HOME/.local/share/waydroid"
	printf 'main image\n' >"$CASE_HOME/Android_Waydroid/waydroid.img"
	printf 'main data\n' >"$CASE_HOME/.local/share/waydroid/main-data"
	MAIN_IMAGE_HASH="$(sha256sum "$CASE_HOME/Android_Waydroid/waydroid.img")"
	MAIN_DATA_HASH="$(sha256sum "$CASE_HOME/.local/share/waydroid/main-data")"
}

assert_main_unchanged() {
	[[ "$(sha256sum "$CASE_HOME/Android_Waydroid/waydroid.img")" == "$MAIN_IMAGE_HASH" ]] ||
		fail 'normal Android image changed'
	[[ "$(sha256sum "$CASE_HOME/.local/share/waydroid/main-data")" == "$MAIN_DATA_HASH" ]] ||
		fail 'normal Waydroid user state changed'
}

setup_case help
set +e
env HOME="$CASE_HOME" PATH="$MOCK_BIN:/usr/bin:/bin" \
	"$REPO_ROOT/steamos-waydroid-installer.sh" invalid extra >"$CASE_ROOT/output" 2>&1
HELP_STATUS=$?
set -e
[[ $HELP_STATUS -ne 0 ]] || fail 'invalid arguments unexpectedly succeeded'
grep -Fq -- '--remove-test' "$CASE_ROOT/output" || fail 'usage omits --remove-test'

setup_case absent
create_main_state
run_remove
[[ $RUN_STATUS -eq 0 ]] || fail 'absent test environment was an error'
grep -Fq 'No Waydroid Test environment was found.' "$CASE_ROOT/output" ||
	fail 'absent test environment was not reported clearly'
[[ ! -s "$MOCK_LOG" ]] || fail 'absent test environment invoked a privileged command'
assert_main_unchanged

setup_case cancelled
create_main_state
mkdir -p "$CASE_HOME/Android_Waydroid/test" "$CASE_HOME/.local/share/waydroid-test/waydroid"
printf 'test image\n' >"$CASE_HOME/Android_Waydroid/test/waydroid.img"
printf 'test data\n' >"$CASE_HOME/.local/share/waydroid-test/waydroid/data"
run_remove 'remove test'
[[ $RUN_STATUS -eq 0 ]] || fail 'incorrect confirmation returned an error'
[[ -f "$CASE_HOME/Android_Waydroid/test/waydroid.img" ]] ||
	fail 'incorrect confirmation removed the test image'
[[ -f "$CASE_HOME/.local/share/waydroid-test/waydroid/data" ]] ||
	fail 'incorrect confirmation removed test user data'
[[ ! -s "$MOCK_LOG" ]] || fail 'incorrect confirmation invoked a privileged command'
assert_main_unchanged

setup_case complete
create_main_state
mkdir -p "$CASE_HOME/Android_Waydroid/test" "$CASE_HOME/.local/share/waydroid-test/waydroid"
printf 'test image\n' >"$CASE_HOME/Android_Waydroid/test/waydroid.img"
printf '16\n' >"$CASE_HOME/Android_Waydroid/test/android-version"
printf 'test data\n' >"$CASE_HOME/.local/share/waydroid-test/waydroid/data"
run_remove 'REMOVE TEST'
[[ $RUN_STATUS -eq 0 ]] || fail 'confirmed test removal failed'
[[ ! -e "$CASE_HOME/Android_Waydroid/test" ]] || fail 'test image state remained'
[[ ! -e "$CASE_HOME/.local/share/waydroid-test" ]] || fail 'test user state remained'
grep -Fq 'Steam shortcuts were not changed.' "$CASE_ROOT/output" ||
	fail 'success output omitted Steam shortcut scope'
grep -Fq 'sudo rm -rf --' "$MOCK_LOG" || fail 'confirmed removal did not delete test roots'
grep -Fq 'STEAM TOOL CALLED' "$MOCK_LOG" && fail 'test removal invoked Steam tooling'
assert_main_unchanged

setup_case partial
create_main_state
mkdir -p "$CASE_HOME/.local/share/waydroid-test/waydroid"
printf 'partial data\n' >"$CASE_HOME/.local/share/waydroid-test/waydroid/data"
run_remove 'REMOVE TEST'
[[ $RUN_STATUS -eq 0 ]] || fail 'partial test state could not be removed'
[[ ! -e "$CASE_HOME/.local/share/waydroid-test" ]] || fail 'partial test state remained'
assert_main_unchanged

setup_case symlink
create_main_state
mkdir -p "$CASE_ROOT/outside"
printf 'outside sentinel\n' >"$CASE_ROOT/outside/keep"
ln -s "$CASE_ROOT/outside" "$CASE_HOME/Android_Waydroid/test"
run_remove 'REMOVE TEST'
[[ $RUN_STATUS -ne 0 ]] || fail 'symlinked test root was accepted'
[[ -f "$CASE_ROOT/outside/keep" ]] || fail 'symlink target was modified'
[[ -L "$CASE_HOME/Android_Waydroid/test" ]] || fail 'unsafe symlink was removed'
[[ ! -s "$MOCK_LOG" ]] || fail 'unsafe path invoked a privileged command'
assert_main_unchanged

setup_case attached
create_main_state
mkdir -p "$CASE_HOME/Android_Waydroid/test"
printf 'test image\n' >"$CASE_HOME/Android_Waydroid/test/waydroid.img"
MOCK_LOOP_ATTACHED=true run_remove 'REMOVE TEST'
unset MOCK_LOOP_ATTACHED
[[ $RUN_STATUS -ne 0 ]] || fail 'attached test image was removed'
[[ -f "$CASE_HOME/Android_Waydroid/test/waydroid.img" ]] ||
	fail 'attached test image did not remain'
grep -Fq 'still attached' "$CASE_ROOT/output" || fail 'attached-image refusal was unclear'
assert_main_unchanged

for dispatch in \
	'--uninstall) UNINSTALL_MODE=true ;;' \
	'--purge-android) PURGE_ANDROID_MODE=true ;;' \
	'--uninstall-all) FULL_UNINSTALL_MODE=true ;;' \
	'--reset-host-keep-android) RESET_HOST_KEEP_ANDROID_MODE=true ;;' \
	'--reinstall-android) REINSTALL_ANDROID_MODE=true ;;'; do
	grep -Fq -- "$dispatch" "$REPO_ROOT/steamos-waydroid-installer.sh" ||
		fail "existing destructive dispatch changed: $dispatch"
done

printf 'ok - isolated and path-safe Waydroid Test removal\n'
