import MessageUI
import SwiftUI
import UIKit

/// A report the person sends themselves, and reads first. It holds the connection log and the
/// device's model and system, and never the chat, tokens or the device's name.
enum MuseProblemReport {
    static let address = "support@exrector.com"

    static var subject: String { "Pal Again \(MuseAppVersion.current) report" }

    static func text(appVersion: String, system: String, model: String, connection: String, log: [String]) -> String {
        """
        What happened:


        ---
        App: Pal Again \(appVersion)
        System: \(system)
        Device: \(model)
        Connection: \(connection)

        Log:
        \(log.isEmpty ? "(empty)" : log.joined(separator: "\n"))
        """
    }
}

private struct MuseMailComposer: UIViewControllerRepresentable {
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([MuseProblemReport.address])
        controller.setSubject(MuseProblemReport.subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }
}

private struct MuseShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// An old gadget often has no mail account, so the report can then leave through any other app.
struct MuseReportSheet: View {
    let body_: String

    var body: some View {
        if MFMailComposeViewController.canSendMail() {
            MuseMailComposer(body: body_)
        } else {
            MuseShareSheet(text: "\(MuseProblemReport.address)\n\(MuseProblemReport.subject)\n\n\(body_)")
        }
    }
}
