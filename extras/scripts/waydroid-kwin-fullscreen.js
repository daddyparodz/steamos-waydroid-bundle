// Keep the Android surface at the compositor's exact logical output size.
// Letting Plasma maximize it into the work area leaves the panel over Android
// and makes its visible controls disagree with their input coordinates.
let activeWaydroidWindow = null;

function isWaydroidWindow(window) {
    const resourceName = (window.resourceName || "").toLowerCase();
    const resourceClass = (window.resourceClass || "").toLowerCase();
    const desktopFileName = (window.desktopFileName || "").toLowerCase();
    return resourceName === "cage" ||
        resourceName === "waydroid" ||
        resourceClass === "waydroid" ||
        resourceClass.startsWith("waydroid.") ||
        desktopFileName === "waydroid" ||
        desktopFileName.startsWith("waydroid.");
}

function fullscreenWaydroid(window) {
    if (window.caption === "Waydroid Touch Navigation") {
        window.fullScreen = true;
        window.noBorder = true;
        window.skipTaskbar = true;
        window.skipSwitcher = true;
        window.keepAbove = true;
        return;
    }
    if (isWaydroidWindow(window)) {
        window.fullScreen = true;
        window.noBorder = true;
        window.keepAbove = false;
    }
}

function activateWaydroid(window) {
    if (!window || !isWaydroidWindow(window)) {
        return;
    }
    if (activeWaydroidWindow && activeWaydroidWindow !== window) {
        activeWaydroidWindow.keepAbove = false;
    }
    window.fullScreen = true;
    window.noBorder = true;
    window.keepAbove = true;
    activeWaydroidWindow = window;
}

workspace.windowList().forEach(fullscreenWaydroid);
workspace.windowAdded.connect(fullscreenWaydroid);
workspace.windowActivated.connect(activateWaydroid);
activateWaydroid(workspace.activeWindow);
