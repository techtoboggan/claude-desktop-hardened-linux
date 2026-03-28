"""Inject Cowork initialization code into the main process entry."""


INIT_CODE = '''\
// --- Cowork for Linux: injected initialization ---
try {
  const { app } = require("electron");
  const coworkInit = require("cowork");
  app.on("ready", () => {
    try {
      coworkInit.initializeCowork();
      console.log("[cowork-linux] Cowork initialized via injection");
    } catch (e) {
      console.error("[cowork-linux] Failed to initialize Cowork:", e.message);
    }
  });
  app.on("before-quit", async () => {
    try {
      await coworkInit.shutdownCowork();
    } catch (e) {
      console.error("[cowork-linux] Shutdown error:", e.message);
    }
  });
} catch (e) {
  console.error("[cowork-linux] Failed to load Cowork module:", e.message);
}
// --- End Cowork injection ---
'''


def apply(content):
    """Prepend Cowork initialization to the main entry."""
    if 'cowork-linux' in content:
        print('  [skip] Cowork init already injected')
        return content, True

    return INIT_CODE + '\n' + content, True
