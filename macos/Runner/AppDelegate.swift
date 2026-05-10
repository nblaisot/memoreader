import Cocoa
import FlutterMacOS
import open_file_handler

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    OpenFileHandlerPlugin.handleOpenURIs(urls)
    super.application(application, open: urls)
  }
}
