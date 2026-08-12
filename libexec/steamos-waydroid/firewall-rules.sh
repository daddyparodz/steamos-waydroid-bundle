#!/usr/bin/env bash

# Shared definitions for the exact firewalld settings managed by this project.
# Callers provide their own privileged command wrapper.

# shellcheck disable=SC2034 # Consumed by scripts which source this library.
FIREWALL_RULE_KEYS=(interface port_53 port_67 forward)
FIREWALL_OWNED_INTERFACE=false
FIREWALL_OWNED_PORT_53=false
FIREWALL_OWNED_PORT_67=false
FIREWALL_OWNED_FORWARD=false

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
	case "$1" in
	interface) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_INTERFACE ;;
	port_53) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_PORT_53 ;;
	port_67) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_PORT_67 ;;
	forward) FIREWALL_OWNED_VARIABLE=FIREWALL_OWNED_FORWARD ;;
	*) return 2 ;;
	esac
}

firewall_rule_is_owned() {
	firewall_owned_variable "$1" || return
	[[ ${!FIREWALL_OWNED_VARIABLE} == true ]]
}

firewall_mark_rule_owned() {
	firewall_owned_variable "$1" || return
	printf -v "$FIREWALL_OWNED_VARIABLE" '%s' true
}

load_firewall_ownership() {
	local ownership_file="$1"
	local key value
	local version_seen=false

	FIREWALL_OWNED_INTERFACE=false
	FIREWALL_OWNED_PORT_53=false
	FIREWALL_OWNED_PORT_67=false
	FIREWALL_OWNED_FORWARD=false

	[[ -e "$ownership_file" || -L "$ownership_file" ]] || return 1
	[[ -f "$ownership_file" && ! -L "$ownership_file" ]] || return 2

	while IFS='=' read -r key value; do
		case "$key" in
		version)
			[[ "$value" == 1 && "$version_seen" == false ]] || return 2
			version_seen=true
			;;
		interface | port_53 | port_67 | forward)
			[[ "$value" == true || "$value" == false ]] || return 2
			firewall_owned_variable "$key" || return
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
		printf 'version=1\n'
		printf 'interface=%s\n' "$FIREWALL_OWNED_INTERFACE"
		printf 'port_53=%s\n' "$FIREWALL_OWNED_PORT_53"
		printf 'port_67=%s\n' "$FIREWALL_OWNED_PORT_67"
		printf 'forward=%s\n' "$FIREWALL_OWNED_FORWARD"
	} >"$staging_file"
	chmod 0600 "$staging_file"
	mv -f -- "$staging_file" "$ownership_file"
}
