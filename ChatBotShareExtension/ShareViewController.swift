import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// UIKit-based entry point for the Share Extension.
/// Extracts shared text/URL from the extension context and presents the SwiftUI share UI.
class ShareViewController: UIViewController {

    private var sharedText: String = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedContent()
    }

    private func extractSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            dismissExtension()
            return
        }

        let group = DispatchGroup()
        var collectedTexts: [String] = []

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // Try plain text first
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                        if let text = item as? String {
                            collectedTexts.append(text)
                        }
                        group.leave()
                    }
                }
                // Try URL
                else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                        if let url = item as? URL {
                            collectedTexts.append(url.absoluteString)
                        }
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.sharedText = collectedTexts.joined(separator: "\n\n")

            if self.sharedText.isEmpty {
                self.dismissExtension()
            } else {
                self.presentShareView()
            }
        }
    }

    private func presentShareView() {
        let shareView = ShareExtensionView(
            sharedText: sharedText,
            onDone: { [weak self] in
                self?.dismissExtension()
            },
            onOpenApp: { [weak self] in
                self?.openMainApp()
            }
        )

        let hostingController = UIHostingController(rootView: shareView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    private func openMainApp() {
        // Use the responder chain to open the main app via URL scheme
        guard let url = URL(string: "chatbot://shared") else {
            dismissExtension()
            return
        }

        var responder: UIResponder? = self
        while let next = responder?.next {
            if let application = next as? UIApplication {
                application.open(url)
                break
            }
            responder = next
        }

        dismissExtension()
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
