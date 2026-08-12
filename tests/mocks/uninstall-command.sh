#!/usr/bin/env bash

set -u

command_name="$(basename -- "$0")"
printf '%s %s\n' "$command_name" "$*" >>"$MOCK_LOG"

case "$command_name" in
id)
	[[ ${1:-} == -un ]] && printf 'deck\n' || /usr/bin/id "$@"
	;;
grep)
	if [[ ${*: -1} == /etc/os-release ]]; then
		exit 0
	fi
	/usr/bin/grep "$@"
	;;
sudo)
	[[ ${1:-} == -v ]] && exit 0
	[[ ${1:-} == test && ${2:-} == -w && ${3:-} == /usr ]] && exit 0
	exec env MOCK_UNDER_SUDO=1 "$@"
	;;
systemctl)
	case "${1:-}" in
	show) printf 'loaded\n' ;;
	stop)
		[[ "$SCENARIO" == service_stop_failure && ${2:-} == waydroid-container.service ]] && exit 1
		exit 0
		;;
	is-active)
		[[ "$SCENARIO" == service_still_active ]] && exit 0
		exit 1
		;;
	esac
	;;
pgrep)
	exit 1
	;;
findmnt)
	if [[ "$*" == *'-T /usr'* ]]; then
		printf 'rw,relatime\n'
	elif [[ "$SCENARIO" == nested_mount ]]; then
		printf '/var/lib/waydroid/data\n'
	fi
	;;
umount)
	exit 0
	;;
losetup)
	if [[ ${1:-} == -j && "$SCENARIO" == loop_remains ]]; then
		printf '/dev/loop7: []: (%s)\n' "${2:-unknown}"
	fi
	;;
firewall-cmd | logger | sync | depmod)
	exit 0
	;;
steamos-readonly)
	printf '%s\n' "${1:-}" >>"$MOCK_STATE/readonly"
	;;
lsmod)
	if [[ ! -e "$MOCK_STATE/binder-unloaded" ]]; then
		printf 'binder_linux 1 0\n'
	fi
	;;
modprobe)
	if [[ "$SCENARIO" == binder_refuses ]]; then
		exit 1
	fi
	: >"$MOCK_STATE/binder-unloaded"
	;;
pacman)
	if [[ ${1:-} == -Qq ]]; then
		/usr/bin/grep -Fxq -- "${2:-}" "$MOCK_STATE/packages"
		exit $?
	fi
	if [[ ${1:-} == -R && ${2:-} == --noconfirm ]]; then
		package="${3:-}"
		if [[ "$SCENARIO" == package_failure && "$package" == python-gbinder ]]; then
			exit 1
		fi
		if [[ "$SCENARIO" == interrupted && "$package" == python-gbinder ]]; then
			kill -TERM "$PPID"
			sleep 0.1
			exit 143
		fi
		if [[ "$SCENARIO" == interrupted_int && "$package" == python-gbinder ]]; then
			kill -INT "$PPID"
			sleep 0.1
			exit 130
		fi
		/usr/bin/grep -Fxv -- "$package" "$MOCK_STATE/packages" >"$MOCK_STATE/packages.new" || true
		/bin/mv "$MOCK_STATE/packages.new" "$MOCK_STATE/packages"
		exit 0
	fi
	exit 2
	;;
rm)
	# The copied test checkout and temporary home are safe. System paths are not.
	for argument in "$@"; do
		case "$argument" in
		/etc/* | /usr/* | /var/*) exit 0 ;;
		esac
	done
	/bin/rm "$@"
	;;
*)
	printf 'unexpected mocked command: %s\n' "$command_name" >&2
	exit 127
	;;
esac
