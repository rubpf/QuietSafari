import Foundation

/// Hands Safari the current rule list. Safari compiles it and applies it itself;
/// this process does not see the pages the user opens.
class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let bundled = Bundle.main.url(forResource: "blockerList", withExtension: "json")
        let url = QuietSafariShared.resolvedRulesURL(bundled: bundled)
        let item = NSExtensionItem()
        if let url, let attachment = NSItemProvider(contentsOf: url) {
            item.attachments = [attachment]
        } else {
            QuietSafariShared.log.error("No content blocker rules were available")
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
