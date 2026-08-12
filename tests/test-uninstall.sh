#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
if [[ ${KEEP_TEST_ROOT:-false} == true ]]; then
	printf 'Keeping uninstall test files at: %s\n' "$TEST_ROOT"
else
	trap 'rm -rf -- "$TEST_ROOT"' EXIT
fi

failures=0

assert_file() {
	if [[ ! -f "$1" ]]; then
		printf 'not ok - expected file: %s\n' "$1" >&2
		return 1
	fi
}

assert_no_file() {
	if [[ -e "$1" || -L "$1" ]]; then
		printf 'not ok - unexpected path: %s\n' "$1" >&2
		return 1
	fi
}

assert_log() {
	local pattern="$1"
	local file="$2"
	if ! grep -Eq -- "$pattern" "$file"; then
		printf 'not ok - log lacks %s: %s\n' "$pattern" "$file" >&2
		return 1
	fi
}

setup_case() {
	local case_name="$1"
	CASE_ROOT="$TEST_ROOT/$case_name"
	CASE_HOME="$CASE_ROOT/home"
	CASE_REPO="$CASE_ROOT/repo"
	MOCK_BIN="$CASE_ROOT/bin"
	MOCK_STATE="$CASE_ROOT/state"
	MOCK_LOG="$CASE_ROOT/commands.log"
	mkdir -p \
		"$CASE_HOME/Android_Waydroid" \
		"$CASE_HOME/.local/share/waydroid" \
		"$CASE_REPO/libexec/steamos-waydroid" \
		"$CASE_REPO/extras" \
		"$MOCK_BIN" "$MOCK_STATE"
	printf 'android image\n' >"$CASE_HOME/Android_Waydroid/waydroid.img"
	cp "$REPO_ROOT/libexec/steamos-waydroid/uninstall.sh" \
		"$CASE_REPO/libexec/steamos-waydroid/uninstall.sh"
	printf '#!/usr/bin/env python3\n' >"$CASE_REPO/extras/icon.py"
	chmod +x "$CASE_REPO/libexec/steamos-waydroid/uninstall.sh"
	: >"$MOCK_LOG"
	printf '%s\n' \
		waydroid python-gbinder libgbinder libglibutil steamos-waydroid-binder \
		>"$MOCK_STATE/packages"
	for command_name in \
		id grep sudo systemctl pgrep findmnt umount losetup firewall-cmd logger \
		sync depmod steamos-readonly lsmod modprobe pacman rm; do
		ln -s "$REPO_ROOT/tests/mocks/uninstall-command.sh" "$MOCK_BIN/$command_name"
	done
}

run_uninstall() {
	local scenario="$1"
	set +e
	printf 'RESET HOST KEEP ANDROID\n' |
		env \
			HOME="$CASE_HOME" \
			PATH="$MOCK_BIN:/usr/bin:/bin" \
			MOCK_LOG="$MOCK_LOG" \
			MOCK_STATE="$MOCK_STATE" \
			SCENARIO="$scenario" \
			STEAMOS_WAYDROID_INTERNAL=1 \
			"$CASE_REPO/libexec/steamos-waydroid/uninstall.sh" \
			--reset-host-keep-android >"$CASE_ROOT/output" 2>&1
	RUN_STATUS=$?
	set -e
}

latest_reset_log() {
	find "$CASE_HOME/.local/state/steamos-waydroid" -type f -name 'reset-*.log' \
		-print -quit
}

run_failure_case() {
	local name="$1"
	local scenario="$2"
	local expected_pattern="$3"
	setup_case "$name"
	run_uninstall "$scenario"
	[[ $RUN_STATUS -ne 0 ]] || return 1
	assert_file "$CASE_HOME/Android_Waydroid/waydroid.img" || return 1
	assert_no_file "$CASE_HOME/.local/state/steamos-waydroid-preserved-reset" || return 1
	assert_log "$expected_pattern" "$CASE_ROOT/output" || return 1
}

test_service_stop_failure() {
	run_failure_case service-stop service_stop_failure 'failed to stop waydroid-container'
}

test_nested_mount_remains() {
	run_failure_case nested-mount nested_mount 'mount is still active below /var/lib/waydroid'
}

test_loop_remains() {
	run_failure_case loop-remains loop_remains 'Android state is still attached'
}

test_binder_refuses() {
	run_failure_case binder-refuses binder_refuses 'binder_linux is still in use' || return 1
	assert_log 'enable' "$MOCK_STATE/readonly" || return 1
}

test_package_failure_partway() {
	run_failure_case package-failure package_failure 'package removal failed: python-gbinder' || return 1
	assert_log '^pacman -R --noconfirm waydroid$' "$MOCK_LOG" || return 1
	assert_log '^pacman -R --noconfirm python-gbinder$' "$MOCK_LOG" || return 1
	assert_log 'enable' "$MOCK_STATE/readonly" || return 1
}

test_term_restores_state() {
	run_failure_case interrupted interrupted 'stage=reset aborted status=143' || return 1
	assert_log 'enable' "$MOCK_STATE/readonly" || return 1
}

test_int_restores_state() {
	run_failure_case interrupted-int interrupted_int 'stage=reset aborted status=130' || return 1
	assert_log 'enable' "$MOCK_STATE/readonly" || return 1
}

test_existing_staging_is_recovered() {
	setup_case staging-recovery
	mkdir -p "$CASE_HOME/.local/state/steamos-waydroid-preserved-reset"
	mv "$CASE_HOME/Android_Waydroid/waydroid.img" \
		"$CASE_HOME/.local/state/steamos-waydroid-preserved-reset/waydroid.img"
	run_uninstall success
	[[ $RUN_STATUS -eq 0 ]] || return 1
	assert_file "$CASE_HOME/Android_Waydroid/waydroid.img" || return 1
	assert_no_file "$CASE_HOME/.local/state/steamos-waydroid-preserved-reset" || return 1
	assert_log 'stage=recover-interrupted-reset complete' "$(latest_reset_log)" || return 1
}

test_ambiguous_staging_is_refused() {
	setup_case staging-ambiguous
	mkdir -p "$CASE_HOME/.local/state/steamos-waydroid-preserved-reset"
	printf 'preserved image\n' \
		>"$CASE_HOME/.local/state/steamos-waydroid-preserved-reset/waydroid.img"
	run_uninstall success
	[[ $RUN_STATUS -ne 0 ]] || return 1
	assert_file "$CASE_HOME/Android_Waydroid/waydroid.img" || return 1
	assert_file "$CASE_HOME/.local/state/steamos-waydroid-preserved-reset/waydroid.img" || return 1
	assert_log 'both active and preserved Android state exist' "$CASE_ROOT/output" || return 1
}

test_success_removes_explicit_packages_separately() {
	setup_case success
	run_uninstall success
	[[ $RUN_STATUS -eq 0 ]] || return 1
	assert_file "$CASE_HOME/Android_Waydroid/waydroid.img" || return 1
	assert_log '^pacman -R --noconfirm waydroid$' "$MOCK_LOG" || return 1
	assert_log '^pacman -R --noconfirm python-gbinder$' "$MOCK_LOG" || return 1
	assert_log '^pacman -R --noconfirm libgbinder$' "$MOCK_LOG" || return 1
	assert_log '^pacman -R --noconfirm libglibutil$' "$MOCK_LOG" || return 1
	if grep -Eq 'pacman -Rn?s|pacman -R .* waydroid .*python-gbinder' "$MOCK_LOG"; then
		printf 'not ok - package removals were combined or used -s\n' >&2
		return 1
	fi
	assert_log 'stage=reset complete' "$(latest_reset_log)" || return 1
}

tests=(
	test_service_stop_failure
	test_nested_mount_remains
	test_loop_remains
	test_binder_refuses
	test_package_failure_partway
	test_term_restores_state
	test_int_restores_state
	test_existing_staging_is_recovered
	test_ambiguous_staging_is_refused
	test_success_removes_explicit_packages_separately
)

for test_name in "${tests[@]}"; do
	if "$test_name"; then
		printf 'ok - %s\n' "$test_name"
	else
		printf 'not ok - %s\n' "$test_name" >&2
		failures=$((failures + 1))
	fi
done

if ((failures > 0)); then
	printf '%d uninstall test(s) failed\n' "$failures" >&2
	exit 1
fi
