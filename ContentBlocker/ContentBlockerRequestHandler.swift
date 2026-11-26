import Foundation

/// Hands Safari one rule list. The same class is compiled into both content blockers;
/// Info.plist QuietSafariRulesName says which file this copy serves.
/// Safari calls this only while the extension is enabled, so the heartbeat is the
/// reliable "on" signal when SFContentBlockerState.isEnabled lags behind the checkbox.
class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let name = (Bundle.main.object(forInfoDictionaryKey: "QuietSafariRulesName") as? String)
            ?? QuietSafariShared.rulesFileName
        QuietSafariShared.markRulesServed(named: name)

        let bundled = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "json")
        let url = QuietSafariShared.resolvedRulesURL(named: name, bundled: bundled)
        let item = NSExtensionItem()
        if let url, let attachment = NSItemProvider(contentsOf: url) {
            attachment.suggestedName = name
            item.attachments = [attachment]
        } else {
            QuietSafariShared.log.error("No content blocker rules were available")
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
