import Cocoa
import FlutterMacOS
import PDFKit

private let kPdfTextChannelName = "com.memoreader.app/pdf_text"

/// Registers a MethodChannel used by Dart on macOS to extract PDF text via PDFKit
/// (`flutter_pdf_text` does not support macOS).
private func registerPdfTextChannel(binaryMessenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(name: kPdfTextChannelName, binaryMessenger: binaryMessenger)
  channel.setMethodCallHandler { call, result in
    guard call.method == "extractText" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let path = call.arguments as? String else {
      result(FlutterError(code: "bad_args", message: "Expected file path string", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    guard let doc = PDFDocument(url: url) else {
      result(FlutterError(code: "open_failed", message: "Could not open PDF", details: nil))
      return
    }
    var parts: [String] = []
    for i in 0..<doc.pageCount {
      guard let page = doc.page(at: i) else { continue }
      let s = page.string ?? ""
      if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(s)
      }
    }
    let text = parts.joined(separator: "\n\n")
    var map: [String: Any] = ["text": text]
    if let attrs = doc.documentAttributes {
      if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty {
        map["title"] = t
      }
      if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String, !a.isEmpty {
        map["author"] = a
      }
    }
    result(map)
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerPdfTextChannel(binaryMessenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
