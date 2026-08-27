#!/usr/bin/env bash

require_bundle_owned_packages_absent() {
	local error_message installed_package package_details package_name package_version
	local -a unexpectedly_installed=()

	printf 'Checking for SteamOS-provided packages that conflict with bundle ownership...\n'
	for package_name in "$@"; do
		if package_details="$(pacman -Q "$package_name" 2>/dev/null)"; then
			installed_package="${package_details%% *}"
			package_version="${package_details#* }"
			printf '  UNEXPECTED  %-20s %s\n' "$installed_package" "$package_version"
			unexpectedly_installed+=("$installed_package")
		else
			printf '  ABSENT      %s\n' "$package_name"
		fi
	done

	((${#unexpectedly_installed[@]} == 0)) && return

	error_message='SteamOS already provides package(s) currently owned by this bundle:'
	for package_name in "${unexpectedly_installed[@]}"; do
		error_message+=$'\n  - '
		error_message+="$package_name"
	done
	error_message+=$'\n\nHost package ownership assumptions changed.'
	error_message+=$'\nDo not build or publish a bundle for this target until the package strategy has been reviewed.'
	die "$error_message"
}
