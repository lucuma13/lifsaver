import AppKit
import LifsaverKit

/// UI flow behind the "Save Diagnostic Report…" menu item: ask for an
/// optional description, pick a destination, then gather the report and
/// reveal the saved file in Finder.
@MainActor
enum DiagnosticReportFlow {
    static func begin(appEvents: [String]) {
        // A menu bar app is never frontmost; without activating, the alert
        // and save panel open behind whatever the user is working in.
        NSApp.activate(ignoringOtherApps: true)

        guard let note = promptForNote() else { return }

        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Report"
        panel.nameFieldStringValue = DiagnosticsReporter.suggestedFilename()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let reporter = DiagnosticsReporter(runner: DefaultProcessRunner())
            let report = await reporter.generate(userNote: note, appEvents: appEvents)
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                offerEmail(for: url)
            } catch {
                NSLog("lifsaver: could not save diagnostic report: %@", "\(error)")
                Notifier.post(title: "lifsaver", body: "Could not save the diagnostic report.")
            }
        }
    }

    /// Post-save hand-off: offer a pre-addressed email. The sharing service
    /// (Apple Mail and most clients) attaches the file automatically; when no
    /// service is available, fall back to a plain mailto: draft whose body
    /// asks the user to attach the saved file themselves.
    private static func offerEmail(for reportURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Report saved"
        alert.informativeText =
            "Click Email Report to send it to \(lifsaverSupportEmail) "
            + "and attach the saved file."
        alert.addButton(withTitle: "Email Report…")
        alert.addButton(withTitle: "Done")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [reportURL]) {
            service.recipients = [lifsaverSupportEmail]
            service.subject = "lifsaver diagnostic report"
            service.perform(withItems: [reportURL])
        } else if let mailto = lifsaverReportMailtoURL(reportFilename: reportURL.lastPathComponent) {
            NSWorkspace.shared.open(mailto)
        }
    }

    /// Free-text "what happened" prompt. Returns nil when the user cancels.
    private static func promptForNote() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Diagnostic Report"
        alert.informativeText =
            "(Optional) Describe the issue. The report will automatically include the technical "
            + "information needed like volume names, and disk layout, and mount paths."

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = textView

        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textView.string
    }
}
