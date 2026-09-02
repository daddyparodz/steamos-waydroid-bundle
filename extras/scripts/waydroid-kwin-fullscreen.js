// Waydroid games often submit frames without waiting for vblank. On the
// Steam Deck's physically portrait panel, the resulting horizontal tear is
// rotated into a prominent vertical seam. Disable tearing only for the
// lifetime of this launcher-loaded script; the launcher restores KWin's
// previous runtime value during cleanup without changing KDE configuration.
options.allowTearing = false;

// Keep the Android surface at the compositor's exact logical output size.
// Letting Plasma maximize it into the work area leaves the panel over Android
// and makes its visible controls disagree with their input coordinates.
function fullscreenWaydroid(window) {
    if (window.caption === "Waydroid Touch Navigation") {
        window.fullScreen = true;
        window.noBorder = true;
        window.skipTaskbar = true;
        window.skipSwitcher = true;
        window.keepAbove = true;
        return;
    }
    const resourceName = (window.resourceName || "").toLowerCase();
    const resourceClass = (window.resourceClass || "").toLowerCase();
    const desktopFileName = (window.desktopFileName || "").toLowerCase();
    if (resourceName === "cage" ||
        resourceName === "waydroid" ||
        resourceClass === "waydroid" ||
        resourceClass.startsWith("waydroid.") ||
        desktopFileName === "waydroid" ||
        desktopFileName.startsWith("waydroid.")) {
        window.fullScreen = true;
        window.noBorder = true;
        // Waydroid keeps separate host surfaces for Android activities. Marking
        // every one keep-above can pin an older login/dialog surface over the
        // currently resumed activity, leaving visible controls unclickable.
        // Fullscreen already places the active surface above Plasma panels.
        window.keepAbove = false;
    }
}

workspace.windowList().forEach(fullscreenWaydroid);
workspace.windowAdded.connect(fullscreenWaydroid);
