// Face Login (Howdy) — menu surface.
//
// The management UI of this plugin is the terminal TUI `face-login-manage`;
// this menu surface simply dispatches to it, or to the installer when
// howdy-next is not installed yet. The shell injects `shell`, `manifest`
// and `omarchyPath` on load, then calls open(payloadJson) on summon and
// close() when hidden.
import Quickshell
import QtQuick

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    return url.replace(/^file:\/\//, "")
  }

  function open(payloadJson) {
    var launcher = "omarchy-launch-floating-terminal-with-presentation"
    Quickshell.execDetached(["bash", "-c",
      "if command -v howdy >/dev/null 2>&1; then " +
      launcher + " face-login-manage; else " +
      launcher + " \"" + pluginDir + "/install.sh\"; fi"])
    if (root.shell && root.manifest && root.manifest.id)
      root.shell.hide(root.manifest.id)
  }

  function close() {}

  function ping() { return "ok" }
}
