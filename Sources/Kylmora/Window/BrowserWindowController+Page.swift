import AppKit
import UniformTypeIdentifiers
import WebKit

/// Print, export, view source, and copy the page as text.
extension BrowserWindowController {
    // MARK: - Printing

    @objc func printPage(_ sender: Any?) {
        guard let webView = session.activeTab?.currentWebView, let window else { return }
        guard let operation = PagePrinting.operation(for: webView) else {
            session.showToast?(Toast(symbolName: "printer", message: "Nothing to print yet", identity: "print"))
            return
        }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func runPageSetup(_ sender: Any?) {
        guard let window else { return }
        NSPageLayout().beginSheet(with: .shared, modalFor: window, delegate: nil, didEnd: nil, contextInfo: nil)
    }

    @objc func exportPageAsPDF(_ sender: Any?) {
        guard let tab = session.activeTab, let webView = tab.currentWebView, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = PagePrinting.suggestedPDFName(title: tab.displayTitle, url: tab.displayURL)
        panel.title = "Export as PDF"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try await PagePrinting.pdfData(of: webView)
                    try data.write(to: file, options: .atomic)
                    self?.session.showToast?(Toast(
                        symbolName: "doc.richtext", message: "Saved \(file.lastPathComponent)", identity: "export-pdf"
                    ))
                } catch {
                    self?.session.showToast?(Toast(
                        symbolName: "exclamationmark.triangle", message: "Could not export the PDF", identity: "export-pdf"
                    ))
                }
            }
        }
    }

    // MARK: - Source

    @objc func viewPageSource(_ sender: Any?) {
        guard let tab = session.activeTab, let webView = tab.currentWebView else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let source = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String,
                  let file = try? PageSource.write(source: source, of: tab.displayURL)
            else { return }
            _ = self.session.newTab(url: file, select: true)
        }
    }

    // MARK: - Copying

    @objc func copyMarkdownLink(_ sender: Any?) {
        guard let tab = session.activeTab else { return }
        put(LinkFormatter.markdown(title: tab.displayTitle, url: tab.displayURL), toast: "Copied as Markdown link")
    }

    @objc func copyTitleAndURL(_ sender: Any?) {
        guard let tab = session.activeTab else { return }
        put(LinkFormatter.titleAndURL(title: tab.displayTitle, url: tab.displayURL), toast: "Copied title and address")
    }

    private func put(_ text: String, toast message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        session.showToast?(Toast(symbolName: "doc.on.clipboard", message: message, identity: "copy-link"))
    }
}
