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
        // A fully opaque fullscreen surface can be scanned out directly. On
        // the Deck's natively portrait LCD, Android portrait buffers may then
        // show vertical line artifacts after KWin rotates them. A practically
        // invisible opacity adjustment keeps only Waydroid in the composited
        // path without changing the output or global compositor settings.
        window.opacity = 0.999;
        // Waydroid keeps separate host surfaces for Android activities. Marking
        // every one keep-above can pin an older login/dialog surface over the
        // currently resumed activity, leaving visible controls unclickable.
        // Fullscreen already places the active surface above Plasma panels.
        window.keepAbove = false;
    }
}

workspace.windowList().forEach(fullscreenWaydroid);
workspace.windowAdded.connect(fullscreenWaydroid);
