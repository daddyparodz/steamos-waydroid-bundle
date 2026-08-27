#!/usr/bin/env bash

# Shared queries about the currently running SteamOS kernel. Keep these checks
# side-effect free: compatibility selection runs before the installer has sudo.

running_kernel_has_builtin_binder() {
	local binder_module binder_filename
	local kernel_release="${STEAMOS_WAYDROID_KERNEL_RELEASE:-$(uname -r)}"
	local modules_root="${STEAMOS_WAYDROID_MODULES_ROOT:-/usr/lib/modules}"
	local modinfo_command="${STEAMOS_WAYDROID_MODINFO:-modinfo}"
	local modules_builtin="$modules_root/$kernel_release/modules.builtin"

	for binder_module in binder_linux binder; do
		binder_filename="$($modinfo_command -k "$kernel_release" -F filename \
			"$binder_module" 2>/dev/null || true)"
		if [[ "$binder_filename" == "(builtin)" ]]; then
			return 0
		fi
	done

	[[ -r "$modules_builtin" ]] &&
		grep -Eq '(^|/)(binder|binder_linux)\.ko$' "$modules_builtin"
}
