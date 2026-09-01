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
    if (window.resourceName === "cage" ||
        window.resourceName === "waydroid" ||
        window.resourceClass === "Waydroid") {
        window.fullScreen = true;
        window.keepAbove = true;
    }
}

workspace.windowList().forEach(fullscreenWaydroid);
workspace.windowAdded.connect(fullscreenWaydroid);
