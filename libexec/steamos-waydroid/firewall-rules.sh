#!/usr/bin/env bash

# Shared definitions for the exact firewalld settings managed by this project.
# Callers provide their own privileged command wrapper.

# shellcheck disable=SC2034 # Consumed by scripts which source this library.
FIREWALL_RULE_KEYS=(interface port_53 port_67 forward)
FIREWALL_OWNED_PERMANENT_INTERFACE=false
FIREWALL_OWNED_PERMANENT_PORT_53=false
FIREWALL_OWNED_PERMANENT_PORT_67=false
FIREWALL_OWNED_PERMANENT_FORWARD=false
FIREWALL_OWNED_RUNTIME_INTERFACE=false
FIREWALL_OWNED_RUNTIME_PORT_53=false
FIREWALL_OWNED_RUNTIME_PORT_67=false
FIREWALL_OWNED_RUNTIME_FORWARD=false

firewall_rule_argument() {
	local operation="$1"
	local key="$2"

	case "$operation:$key" in
	query:interface) FIREWALL_RULE_ARGUMENT="--query-interface=waydroid0" ;;
	add:interface) FIREWALL_RULE_ARGUMENT="--add-interface=waydroid0" ;;
	remove:interface) FIREWALL_RULE_ARGUMENT="--remove-interface=waydroid0" ;;
	query:port_53) FIREWALL_RULE_ARGUMENT="--query-port=53/udp" ;;
	add:port_53) FIREWALL_RULE_ARGUMENT="--add-port=53/udp" ;;
	remove:port_53) FIREWALL_RULE_ARGUMENT="--remove-port=53/udp" ;;
	query:port_67) FIREWALL_RULE_ARGUMENT="--query-port=67/udp" ;;
	add:port_67) FIREWALL_RULE_ARGUMENT="--add-port=67/udp" ;;
	remove:port_67) FIREWALL_RULE_ARGUMENT="--remove-port=67/udp" ;;
	query:forward) FIREWALL_RULE_ARGUMENT="--query-forward" ;;
	add:forward) FIREWALL_RULE_ARGUMENT="--add-forward" ;;
	remove:forward) FIREWALL_RULE_ARGUMENT="--remove-forward" ;;
	*) return 2 ;;
	esac
}

firewall_rule_command() {
	local operation="$1"
	local key="$2"
	shift 2

	firewall_rule_argument "$operation" "$key" || return
	"$@" --zone=trusted "$FIREWALL_RULE_ARGUMENT"
}

firewall_owned_variable() {
	local scope="$1"
	local key="$2"

	case "$scope:$key" in
	permanent:interface) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_PERMANENT_INTERFACE ;;
	permanent:port_53) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_PERMANENT_PORT_53 ;;
	permanent:port_67) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_PERMANENT_PORT_67 ;;
	permanent:forward) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_PERMANENT_FORWARD ;;
	runtime:interface) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_RUNTIME_INTERFACE ;;
	runtime:port_53) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_RUNTIME_PORT_53 ;;
	runtime:port_67) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_RUNTIME_PORT_67 ;;
	runtime:forward) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_RUNTIME_FORWARD ;;
	*) return 2 ;;
	esac
}

firewall_rule_is_owned() {
	firewall_owned_variable "$1" "$2" || return
	[[ ${!FIREWALL_OWNED_VARIABLE} == true ]]
}

firewall_mark_rule_owned() {
	firewall_owned_variable "$1" "$2" || return
	printf -v "$FIREWALL_OWNED_VARIABLE" '%s' true
}

firewall_clear_rule_owned() {
	firewall_owned_variable "$1" "$2" || return
	printf -v "$FIREWALL_OWNED_VARIABLE" '%s' false
}

reset_firewall_ownership() {
	local scope key

	for scope in permanent runtime; do
		for key in "${FIREWALL_RULE_KEYS[@]}"; do
			firewall_clear_rule_owned "$scope" "$key"
		done
	done
}

load_firewall_ownership() {
	local ownership_file="$1"
	local key value scope rule_key
	local version="" version_seen=false

	reset_firewall_ownership

	[[ -e "$ownership_file" || -L "$ownership_file" ]] || return 1
	[[ -f "$ownership_file" && ! -L "$ownership_file" ]] || return 2

	while IFS='=' read -r key value; do
		case "$key" in
		version)
			[[ ("$value" == 1 || "$value" == 2) && "$version_seen" == false ]] || return 2
			version="$value"
			version_seen=true
			;;
		interface | port_53 | port_67 | forward)
			[[ "$version" == 1 ]] || return 2
			[[ "$value" == true || "$value" == false ]] || return 2
			# Version 1 tracked only permanent additions. Never infer ownership
			# of a runtime rule from a legacy record.
			firewall_owned_variable permanent "$key" || return
			printf -v "$FIREWALL_OWNED_VARIABLE" '%s' "$value"
			;;
		permanent_interface | permanent_port_53 | permanent_port_67 | permanent_forward | \
			runtime_interface | runtime_port_53 | runtime_port_67 | runtime_forward)
			[[ "$version" == 2 ]] || return 2
			[[ "$value" == true || "$value" == false ]] || return 2
			scope="${key%%_*}"
			rule_key="${key#*_}"
			firewall_owned_variable "$scope" "$rule_key" || return
			printf -v "$FIREWALL_OWNED_VARIABLE" '%s' "$value"
			;;
		*) return 2 ;;
		esac
	done <"$ownership_file"

	[[ "$version_seen" == true ]]
}

write_firewall_ownership() {
	local ownership_file="$1"
	local ownership_directory staging_file

	ownership_directory="$(dirname -- "$ownership_file")"
	mkdir -p -- "$ownership_directory"
	staging_file="$(mktemp "$ownership_directory/.firewall-ownership.XXXXXX")"
	{
		printf 'version=2\n'
		printf 'permanent_interface=%s\n' "$FIREWALL_OWNED_PERMANENT_INTERFACE"
		printf 'permanent_port_53=%s\n' "$FIREWALL_OWNED_PERMANENT_PORT_53"
		printf 'permanent_port_67=%s\n' "$FIREWALL_OWNED_PERMANENT_PORT_67"
		printf 'permanent_forward=%s\n' "$FIREWALL_OWNED_PERMANENT_FORWARD"
		printf 'runtime_interface=%s\n' "$FIREWALL_OWNED_RUNTIME_INTERFACE"
		printf 'runtime_port_53=%s\n' "$FIREWALL_OWNED_RUNTIME_PORT_53"
		printf 'runtime_port_67=%s\n' "$FIREWALL_OWNED_RUNTIME_PORT_67"
		printf 'runtime_forward=%s\n' "$FIREWALL_OWNED_RUNTIME_FORWARD"
	} >"$staging_file"
	chmod 0600 "$staging_file"
	mv -f -- "$staging_file" "$ownership_file"
}

rollback_firewall_transaction() {
	local privileged_command="$1"
	local firewalld_was_active="$2"
	local log_file="$3"
	shift 3
	local rollback_entry rollback_scope rollback_rule rollback_index
	local rollback_failed=false
	local -a added_rules=("$@")

	# Runtime configuration is only addressable while firewalld is active.
	# Restarting a service which was initially inactive is temporary and is
	# undone again after rollback.
	if ! systemctl is-active --quiet firewalld.service; then
		"$privileged_command" systemctl start firewalld >>"$log_file" 2>&1 ||
			rollback_failed=true
	fi

	for ((rollback_index = ${#added_rules[@]} - 1; rollback_index >= 0; rollback_index--)); do
		rollback_entry="${added_rules[$rollback_index]}"
		rollback_scope="${rollback_entry%%:*}"
		rollback_rule="${rollback_entry#*:}"

		if [[ "$rollback_scope" == runtime ]]; then
			if systemctl is-active --quiet firewalld.service; then
				firewall_rule_command remove "$rollback_rule" \
					"$privileged_command" firewall-cmd >>"$log_file" 2>&1 ||
					rollback_failed=true
			fi
		elif systemctl is-active --quiet firewalld.service; then
			firewall_rule_command remove "$rollback_rule" \
				"$privileged_command" firewall-cmd --permanent >>"$log_file" 2>&1 ||
				rollback_failed=true
		else
			firewall_rule_command remove "$rollback_rule" \
				"$privileged_command" firewall-offline-cmd >>"$log_file" 2>&1 ||
				rollback_failed=true
		fi
		firewall_clear_rule_owned "$rollback_scope" "$rollback_rule"
	done

	if [[ "$firewalld_was_active" != true ]] &&
		systemctl is-active --quiet firewalld.service; then
		"$privileged_command" systemctl stop firewalld >>"$log_file" 2>&1 ||
			rollback_failed=true
	fi

	[[ "$rollback_failed" == false ]]
}

configure_firewall_rules() {
	local ownership_file="$1"
	local firewalld_was_active="$2"
	local log_file="$3"
	local privileged_command="$4"
	local ownership_status query_status scope rule
	local setup_failed=false
	local -a firewall_command=()
	local -a added_rules=()

	if [[ "$firewalld_was_active" == true ]]; then
		"$privileged_command" firewall-cmd --check-config >>"$log_file" 2>&1 || return 1
	else
		"$privileged_command" firewall-offline-cmd --check-config >>"$log_file" 2>&1 || return 1
	fi

	if load_firewall_ownership "$ownership_file"; then
		:
	else
		ownership_status=$?
		((ownership_status == 1)) || return 2
	fi

	"$privileged_command" systemctl start firewalld >>"$log_file" 2>&1 || return 1

	for rule in "${FIREWALL_RULE_KEYS[@]}"; do
		for scope in permanent runtime; do
			firewall_command=("$privileged_command" firewall-cmd)
			[[ "$scope" == runtime ]] || firewall_command+=(--permanent)

			if firewall_rule_command query "$rule" "${firewall_command[@]}" >/dev/null 2>&1; then
				continue
			else
				query_status=$?
			fi
			if ((query_status != 1)) ||
				! firewall_rule_command add "$rule" "${firewall_command[@]}" >>"$log_file" 2>&1; then
				setup_failed=true
				break 2
			fi
			firewall_mark_rule_owned "$scope" "$rule"
			added_rules+=("$scope:$rule")
		done
	done

	if [[ "$setup_failed" == false ]] &&
		! "$privileged_command" firewall-cmd --check-config >>"$log_file" 2>&1; then
		setup_failed=true
	fi

	if [[ "$setup_failed" == false && "$firewalld_was_active" != true ]]; then
		if ! "$privileged_command" systemctl stop firewalld >>"$log_file" 2>&1; then
			setup_failed=true
		else
			# Stopping firewalld discards the runtime configuration from this
			# daemon lifetime, so no runtime additions remain owned.
			for rule in "${FIREWALL_RULE_KEYS[@]}"; do
				firewall_clear_rule_owned runtime "$rule"
			done
		fi
	fi

	if [[ "$setup_failed" == false ]] && write_firewall_ownership "$ownership_file"; then
		return 0
	fi

	rollback_firewall_transaction \
		"$privileged_command" "$firewalld_was_active" "$log_file" \
		"${added_rules[@]}" ||
		printf 'warning: firewall transaction rollback was incomplete\n' >&2
	return 1
}
