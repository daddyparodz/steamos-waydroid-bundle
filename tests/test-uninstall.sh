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
	MOCK_FIREWALL_ROOT="$CASE_ROOT/firewalld"
	mkdir -p \
		"$CASE_HOME/Android_Waydroid" \
		"$CASE_HOME/.local/share/waydroid" \
		"$CASE_REPO/libexec/steamos-waydroid" \
		"$CASE_REPO/extras" \
		"$MOCK_BIN" "$MOCK_STATE" \
		"$MOCK_FIREWALL_ROOT/zones" "$MOCK_FIREWALL_ROOT/policies"
	printf 'android image\n' >"$CASE_HOME/Android_Waydroid/waydroid.img"
	cp "$REPO_ROOT/libexec/steamos-waydroid/uninstall.sh" \
		"$CASE_REPO/libexec/steamos-waydroid/uninstall.sh"
	cp "$REPO_ROOT/libexec/steamos-waydroid/firewall-rules.sh" \
		"$CASE_REPO/libexec/steamos-waydroid/firewall-rules.sh"
	printf '#!/usr/bin/env python3\n' >"$CASE_REPO/extras/icon.py"
	chmod +x "$CASE_REPO/libexec/steamos-waydroid/uninstall.sh"
	: >"$MOCK_LOG"
	printf '%s\n' \
		waydroid python-gbinder libgbinder libglibutil steamos-waydroid-binder \
		>"$MOCK_STATE/packages"
	: >"$MOCK_STATE/runtime_rules"
	: >"$MOCK_STATE/permanent_rules"
	printf '<zone name="trusted"/>\n' >"$MOCK_FIREWALL_ROOT/zones/trusted.xml"
	for command_name in \
		id grep sudo systemctl pgrep findmnt umount losetup firewall-cmd \
		firewall-offline-cmd logger \
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
			MOCK_FIREWALL_ROOT="$MOCK_FIREWALL_ROOT" \
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

configure_firewall_case() {
	local rules_present="$1"
	local fixture

	mkdir -p "$CASE_HOME/.local/share/steamos-waydroid-installer"
	cat >"$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env" <<'EOF'
version=2
permanent_interface=true
permanent_port_53=true
permanent_port_67=true
permanent_forward=true
runtime_interface=true
runtime_port_53=true
runtime_port_67=true
runtime_forward=true
EOF
	if [[ "$rules_present" == true ]]; then
		printf '%s\n' interface port_53 port_67 forward >"$MOCK_STATE/runtime_rules"
		cp "$MOCK_STATE/runtime_rules" "$MOCK_STATE/permanent_rules"
	fi
	for fixture in \
		block dmz drop external home internal nm-shared public work; do
		printf '<zone name="%s"><service name="custom-%s"/></zone>\n' \
			"$fixture" "$fixture" >"$MOCK_FIREWALL_ROOT/zones/$fixture.xml"
	done
	printf '<policy name="allow-host-ipv6"><service name="custom"/></policy>\n' \
		>"$MOCK_FIREWALL_ROOT/policies/allow-host-ipv6.xml"
	find "$MOCK_FIREWALL_ROOT" -type f ! -name trusted.xml -print0 |
		sort -z | xargs -0 sha256sum >"$CASE_ROOT/firewall-before.sha256"
}

assert_unrelated_firewall_unchanged() {
	sha256sum --check --status "$CASE_ROOT/firewall-before.sha256"
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

test_loaded_binder_is_not_unloaded() {
	setup_case binder-retained
	run_uninstall binder_refuses
	[[ $RUN_STATUS -eq 0 ]] || return 1
	assert_log 'stage=binder-live-state retained' "$CASE_ROOT/output" || return 1
	if grep -Eq '^(sudo )?modprobe -r binder_linux$' "$MOCK_LOG"; then
		printf 'not ok - reset attempted to unload live binder_linux\n' >&2
		return 1
	fi
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
	assert_log 'fully restart SteamOS before doing anything else' "$CASE_ROOT/output" || return 1
	if grep -Eq 'pacman -Rn?s|pacman -R .* waydroid .*python-gbinder' "$MOCK_LOG"; then
		printf 'not ok - package removals were combined or used -s\n' >&2
		return 1
	fi
	assert_log 'stage=reset complete' "$(latest_reset_log)" || return 1
}

test_firewall_active_targeted_cleanup() {
	setup_case firewall-active
	configure_firewall_case true
	run_uninstall firewall_active
	[[ $RUN_STATUS -eq 0 ]] || return 1
	[[ ! -s "$MOCK_STATE/runtime_rules" && ! -s "$MOCK_STATE/permanent_rules" ]] || return 1
	assert_unrelated_firewall_unchanged || return 1
	assert_log '^firewall-cmd --check-config$' "$MOCK_LOG" || return 1
	assert_log '^firewall-cmd --zone=trusted --remove-forward$' "$MOCK_LOG" || return 1
	assert_log '^firewall-cmd --permanent --zone=trusted --remove-forward$' "$MOCK_LOG" || return 1
	if grep -Eq '^systemctl (start|stop) firewalld' "$MOCK_LOG"; then
		printf 'not ok - active firewalld service state was changed\n' >&2
		return 1
	fi
}

test_firewall_inactive_offline_cleanup() {
	setup_case firewall-inactive
	configure_firewall_case true
	run_uninstall firewall_inactive
	[[ $RUN_STATUS -eq 0 ]] || return 1
	[[ ! -s "$MOCK_STATE/permanent_rules" ]] || return 1
	assert_unrelated_firewall_unchanged || return 1
	assert_log '^firewall-offline-cmd --check-config$' "$MOCK_LOG" || return 1
	assert_log '^firewall-offline-cmd --zone=trusted --remove-forward$' "$MOCK_LOG" || return 1
	if grep -Eq '^systemctl (start|stop) firewalld' "$MOCK_LOG"; then
		printf 'not ok - inactive firewalld service state was changed\n' >&2
		return 1
	fi
}

test_firewall_absent_rules_are_idempotent() {
	setup_case firewall-absent
	configure_firewall_case false
	run_uninstall firewall_active_absent
	[[ $RUN_STATUS -eq 0 ]] || return 1
	assert_unrelated_firewall_unchanged || return 1
	if grep -Eq 'firewall-(cmd|offline-cmd).*--remove-' "$MOCK_LOG"; then
		printf 'not ok - absent firewall rules triggered removals\n' >&2
		return 1
	fi
}

test_firewall_unowned_forward_is_preserved() {
	setup_case firewall-unowned-forward
	configure_firewall_case true
	sed -i 's/^permanent_forward=true$/permanent_forward=false/; s/^runtime_forward=true$/runtime_forward=false/' \
		"$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env"
	run_uninstall firewall_active
	[[ $RUN_STATUS -eq 0 ]] || return 1
	[[ "$(cat "$MOCK_STATE/runtime_rules")" == forward ]] || return 1
	[[ "$(cat "$MOCK_STATE/permanent_rules")" == forward ]] || return 1
	if grep -Eq 'firewall-cmd .*--remove-forward' "$MOCK_LOG"; then
		printf 'not ok - pre-existing unowned forward setting was removed\n' >&2
		return 1
	fi
	assert_unrelated_firewall_unchanged || return 1
}

test_firewall_preexisting_runtime_rule_is_preserved() {
	setup_case firewall-preexisting-runtime
	configure_firewall_case false
	printf '%s\n' forward >"$MOCK_STATE/runtime_rules"
	printf '%s\n' forward >"$MOCK_STATE/permanent_rules"
	sed -i 's/^runtime_forward=true$/runtime_forward=false/' \
		"$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env"
	run_uninstall firewall_active
	[[ $RUN_STATUS -eq 0 ]] || return 1
	[[ "$(cat "$MOCK_STATE/runtime_rules")" == forward ]] || return 1
	[[ ! -s "$MOCK_STATE/permanent_rules" ]] || return 1
	if grep -Eq '^firewall-cmd --zone=trusted --remove-forward$' "$MOCK_LOG"; then
		printf 'not ok - pre-existing runtime rule was removed\n' >&2
		return 1
	fi
}

test_firewall_failed_install_rolls_back_new_rules() {
	setup_case firewall-install-rollback
	printf '%s\n' forward >"$MOCK_STATE/runtime_rules"
	printf '%s\n' forward >"$MOCK_STATE/permanent_rules"

	set +e
	(
		export PATH="$MOCK_BIN:/usr/bin:/bin"
		export MOCK_LOG MOCK_STATE MOCK_FIREWALL_ROOT
		export SCENARIO=firewall_active_runtime_add_failure
		source "$REPO_ROOT/libexec/steamos-waydroid/firewall-rules.sh"
		firewall_test_privileged() {
			"$@"
		}
		configure_firewall_rules \
			"$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env" \
			true "$CASE_ROOT/firewall-install.log" firewall_test_privileged
	)
	transaction_status=$?
	set -e

	[[ $transaction_status -ne 0 ]] || return 1
	[[ "$(cat "$MOCK_STATE/runtime_rules")" == forward ]] || return 1
	[[ "$(cat "$MOCK_STATE/permanent_rules")" == forward ]] || return 1
	assert_no_file \
		"$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env" || return 1
	assert_log '^firewall-cmd --zone=trusted --remove-interface=waydroid0$' "$MOCK_LOG" || return 1
	assert_log '^firewall-cmd --permanent --zone=trusted --remove-port=53/udp$' "$MOCK_LOG" || return 1
}

test_firewall_install_records_scoped_ownership() {
	setup_case firewall-install-ownership
	printf '%s\n' forward >"$MOCK_STATE/runtime_rules"
	printf '%s\n' forward >"$MOCK_STATE/permanent_rules"

	(
		export PATH="$MOCK_BIN:/usr/bin:/bin"
		export MOCK_LOG MOCK_STATE MOCK_FIREWALL_ROOT
		export SCENARIO=firewall_active
		source "$REPO_ROOT/libexec/steamos-waydroid/firewall-rules.sh"
		firewall_test_privileged() {
			"$@"
		}
		configure_firewall_rules \
			"$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env" \
			true "$CASE_ROOT/firewall-install.log" firewall_test_privileged
	) || return 1

	ownership_file="$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env"
	assert_log '^version=2$' "$ownership_file" || return 1
	assert_log '^permanent_interface=true$' "$ownership_file" || return 1
	assert_log '^runtime_interface=true$' "$ownership_file" || return 1
	assert_log '^permanent_forward=false$' "$ownership_file" || return 1
	assert_log '^runtime_forward=false$' "$ownership_file" || return 1
	[[ "$(sort "$MOCK_STATE/runtime_rules")" == $'forward\ninterface\nport_53\nport_67' ]] || return 1
	[[ "$(sort "$MOCK_STATE/permanent_rules")" == $'forward\ninterface\nport_53\nport_67' ]] || return 1
}

test_firewall_v1_ownership_is_permanent_only() {
	setup_case firewall-v1
	configure_firewall_case true
	cat >"$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env" <<'EOF'
version=1
interface=true
port_53=true
port_67=true
forward=true
EOF
	run_uninstall firewall_active
	[[ $RUN_STATUS -eq 0 ]] || return 1
	[[ "$(cat "$MOCK_STATE/runtime_rules")" == $'interface\nport_53\nport_67\nforward' ]] || return 1
	[[ ! -s "$MOCK_STATE/permanent_rules" ]] || return 1
	if grep -Eq '^firewall-cmd --zone=trusted --remove-' "$MOCK_LOG"; then
		printf 'not ok - legacy ownership removed a runtime rule\n' >&2
		return 1
	fi
}

test_firewall_invalid_configuration_fails_closed() {
	setup_case firewall-invalid
	configure_firewall_case true
	run_uninstall firewall_invalid
	[[ $RUN_STATUS -ne 0 ]] || return 1
	assert_file "$CASE_HOME/Android_Waydroid/waydroid.img" || return 1
	assert_file "$CASE_HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env" || return 1
	assert_unrelated_firewall_unchanged || return 1
	assert_log 'configuration is invalid; refusing to modify it' "$CASE_ROOT/output" || return 1
	if grep -Eq 'firewall-(cmd|offline-cmd).*--remove-' "$MOCK_LOG"; then
		printf 'not ok - invalid firewall configuration was modified\n' >&2
		return 1
	fi
}

test_firewall_cleanup_second_reset_is_safe() {
	setup_case firewall-second-reset
	configure_firewall_case true
	run_uninstall firewall_active
	[[ $RUN_STATUS -eq 0 ]] || return 1
	first_removal_count="$(grep -Ec 'firewall-cmd .*--remove-' "$MOCK_LOG")"
	run_uninstall firewall_active
	[[ $RUN_STATUS -eq 0 ]] || return 1
	second_removal_count="$(grep -Ec 'firewall-cmd .*--remove-' "$MOCK_LOG")"
	[[ "$second_removal_count" == "$first_removal_count" ]] || return 1
	assert_unrelated_firewall_unchanged || return 1
}

test_no_runtime_to_permanent_in_project_firewall_paths() {
	if rg -n -- '--runtime-to-permanent' \
		"$REPO_ROOT/libexec/steamos-waydroid/uninstall.sh" \
		"$REPO_ROOT/steamos-waydroid-installer.sh" \
		"$REPO_ROOT/extras/scripts/Waydroid-Toolbox.sh"; then
		printf 'not ok - broad runtime-to-permanent operation remains\n' >&2
		return 1
	fi
}

tests=(
	test_service_stop_failure
	test_nested_mount_remains
	test_loop_remains
	test_loaded_binder_is_not_unloaded
	test_package_failure_partway
	test_term_restores_state
	test_int_restores_state
	test_existing_staging_is_recovered
	test_ambiguous_staging_is_refused
	test_success_removes_explicit_packages_separately
	test_firewall_active_targeted_cleanup
	test_firewall_inactive_offline_cleanup
	test_firewall_absent_rules_are_idempotent
	test_firewall_unowned_forward_is_preserved
	test_firewall_preexisting_runtime_rule_is_preserved
	test_firewall_v1_ownership_is_permanent_only
	test_firewall_failed_install_rolls_back_new_rules
	test_firewall_install_records_scoped_ownership
	test_firewall_invalid_configuration_fails_closed
	test_firewall_cleanup_second_reset_is_safe
	test_no_runtime_to_permanent_in_project_firewall_paths
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
