#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2209 # Variables are consumed by sourced installer helpers.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME/Android_Waydroid" "$TEST_HOME/.local/share/waydroid" \
	"$TEST_ROOT/work/extras"

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

printf 'main image sentinel\n' >"$TEST_HOME/Android_Waydroid/waydroid.img"
printf 'main data sentinel\n' >"$TEST_HOME/.local/share/waydroid/main-data"
MAIN_IMAGE_HASH="$(sha256sum "$TEST_HOME/Android_Waydroid/waydroid.img")"
MAIN_DATA_HASH="$(sha256sum "$TEST_HOME/.local/share/waydroid/main-data")"

export HOME=$TEST_HOME
# shellcheck source=../libexec/steamos-waydroid/waydroid-profile.sh
source "$REPO_ROOT/libexec/steamos-waydroid/waydroid-profile.sh"
# shellcheck source=../libexec/steamos-waydroid/installer-functions.sh
source "$REPO_ROOT/libexec/steamos-waydroid/installer-functions.sh"

resolve_waydroid_profile test
test_environment_install_allowed ||
	fail 'existing main installation prevented a test installation'
[[ "$WAYDROID_IMAGE" == "$TEST_HOME/Android_Waydroid/test/waydroid.img" ]] ||
	fail 'test installer resolved the wrong final image'
[[ "$WAYDROID_XDG_DATA_HOME" == "$TEST_HOME/.local/share/waydroid-test" ]] ||
	fail 'test installer resolved the wrong XDG data home'
[[ "$WAYDROID_USER_STATE" == "$TEST_HOME/.local/share/waydroid-test/waydroid" ]] ||
	fail 'test installer resolved the wrong user state'

printf 'new test image\n' >"$TEST_ROOT/staged.img"
commit_new_android_image "$TEST_ROOT/staged.img"
[[ -f "$TEST_HOME/Android_Waydroid/test/waydroid.img" ]] ||
	fail 'test image was not committed under Android_Waydroid/test'
[[ "$(sha256sum "$TEST_HOME/Android_Waydroid/waydroid.img")" == "$MAIN_IMAGE_HASH" ]] ||
	fail 'committing the test image changed the main image'
[[ "$(sha256sum "$TEST_HOME/.local/share/waydroid/main-data")" == "$MAIN_DATA_HASH" ]] ||
	fail 'committing the test image changed main user data'

if test_environment_install_allowed 2>"$TEST_ROOT/already-installed.log"; then
	fail 'an existing test image was accepted for installation'
fi
grep -Fq 'Waydroid Test is already installed.' "$TEST_ROOT/already-installed.log" ||
	fail 'existing test image refusal was unclear'

# A failed test installation may remove only the test profile's paths and
# temporary image. It must leave both main sentinels byte-for-byte unchanged.
mkdir -p "$WAYDROID_USER_STATE"
printf 'partial test data\n' >"$WAYDROID_USER_STATE/partial"
printf 'temporary image\n' >"$TEST_ROOT/work/extras/waydroid.img"
WORKING_DIR="$TEST_ROOT/work"
LOGFILE="$TEST_ROOT/work/logfile-test"
current_password=test
TEST_INSTALL_CLEANUP_DONE=false
sudo() {
	[[ ${1:-} != -S ]] || shift
	case "${1:-}" in
	systemctl | steamos-readonly) return 0 ;;
	*) "$@" ;;
	esac
}
unmount_waydroid_var() { :; }
restore_decky_loader() { :; }
cleanup_failed_test_environment
[[ ! -e "$TEST_HOME/Android_Waydroid/test" ]] || fail 'failed test image directory remained'
[[ ! -e "$TEST_HOME/.local/share/waydroid-test" ]] || fail 'failed test user state remained'
[[ "$(sha256sum "$TEST_HOME/Android_Waydroid/waydroid.img")" == "$MAIN_IMAGE_HASH" ]] ||
	fail 'test failure cleanup changed the main image'
[[ "$(sha256sum "$TEST_HOME/.local/share/waydroid/main-data")" == "$MAIN_DATA_HASH" ]] ||
	fail 'test failure cleanup changed main user data'

# The tiny test launcher must delegate to the existing launcher with the
# constrained profile argument rather than duplicating Cage logic.
mkdir -p "$TEST_ROOT/launcher"
cp "$REPO_ROOT/extras/scripts/Android_Waydroid_Test_Cage.sh" "$TEST_ROOT/launcher/"
cat >"$TEST_ROOT/launcher/Android_Waydroid_Cage.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ROOT/launcher-args"
EOF
chmod +x "$TEST_ROOT/launcher/"*.sh
export TEST_ROOT
"$TEST_ROOT/launcher/Android_Waydroid_Test_Cage.sh"
[[ "$(sed -n '1p' "$TEST_ROOT/launcher-args")" == --profile ]] ||
	fail 'Waydroid Test launcher omitted --profile'
[[ "$(sed -n '2p' "$TEST_ROOT/launcher-args")" == test ]] ||
	fail 'Waydroid Test launcher did not select test'

python3 - "$REPO_ROOT" "$TEST_ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

repo = Path(sys.argv[1])
root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("shortcut_manager", repo / "extras/icon.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.TARGETS["waydroid"]["name"] == "Waydroid"
assert module.TARGETS["waydroid-test"]["name"] == "Waydroid Test"
assert module.TARGETS["waydroid"]["executables"] == ("Android_Waydroid_Cage.sh",)
assert module.TARGETS["waydroid-test"]["executables"] == ("Android_Waydroid_Test_Cage.sh",)

shortcut_path = root / "userdata/1/config/shortcuts.vdf"
shortcut_path.parent.mkdir(parents=True)
normal = {"appid": 101, "Exe": str(root / "Android_Waydroid_Cage.sh"), "AppName": "Waydroid"}
test = {"appid": 202, "Exe": str(root / "Android_Waydroid_Test_Cage.sh"), "AppName": "Waydroid Test"}
normal_assets = module.find_artwork_assets(repo / "extras/icons/waydroid")
test_assets = module.find_artwork_assets(repo / "extras/icons/waydroid-test")
normal_installed = module.install_artwork(shortcut_path, normal, normal_assets)
test_installed = module.install_artwork(shortcut_path, test, test_assets)
for artwork_type, source in normal_assets.items():
    assert normal_installed[artwork_type].read_bytes() == source.read_bytes()
for artwork_type, source in test_assets.items():
    assert test_installed[artwork_type].read_bytes() == source.read_bytes()
assert set(normal_installed.values()).isdisjoint(test_installed.values())
PY

grep -Fq -- '--install-test' "$REPO_ROOT/steamos-waydroid-installer.sh" ||
	fail 'installer does not expose the test action'
grep -Fq -- '--artwork-dir "$WORKING_DIR/extras/icons/waydroid-test"' \
	"$REPO_ROOT/steamos-waydroid-installer.sh" ||
	fail 'test shortcut does not select supplied test artwork'
grep -Fq 'export XDG_DATA_HOME=$WAYDROID_XDG_DATA_HOME' \
	"$REPO_ROOT/steamos-waydroid-installer.sh" ||
	fail 'test installation does not export its XDG data home'

printf 'ok - isolated Waydroid Test installation, launcher, cleanup, and artwork\n'
