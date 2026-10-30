import AppKit
import ReflexHelperCore

// DSH Reflex Helper: an LSUIElement app that holds the Accessibility grant and supervises programs.
let options = HelperOptions.parse(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let service = HelperService(options: options)
do {
  try service.start()
} catch {
  FileHandle.standardError.write(Data("reflex-helper: \(error)\n".utf8))
  exit(75)
}
let menuBar = MenuBarController(service: service)
withExtendedLifetime(menuBar) { app.run() }
