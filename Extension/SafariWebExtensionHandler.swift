import Foundation
import SafariServices

/// Receives messages from the web extension background script.
/// Safari delivers the JSON object in SFExtensionMessageKey and expects the same key in the reply.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let reply = QuietSafariBridge.reply(to: message)

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
