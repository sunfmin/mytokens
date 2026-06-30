import XCTest
import AppKit

/// Renders the real secret dialog to `out/secret-prompt.png` and asserts the
/// must-show content actually reached the view (rule 4) — proving the
/// service/account seam data flows through the real layout into the UI, not just
/// that a PNG got written. Eyeball the PNG once; these asserts guard it forever.
final class SecretPromptRenderTests: XCTestCase {

    func testRendersSecretPrompt() {
        let (path, view) = renderToImage("secret-prompt") {
            SecretPromptView.make(service: "cloudflare", account: "default")
        }

        let texts = view.allSubviews.compactMap { ($0 as? NSTextField)?.stringValue }

        // Seam data reached the UI as the confirmation chip.
        XCTAssertTrue(texts.contains("cloudflare / default"), "chip missing; got \(texts)")
        // The dialog states its job and where the value goes.
        XCTAssertTrue(texts.contains("Store a secret"))
        XCTAssertTrue(texts.contains { $0.contains("never shown to the agent") })

        // The value field is masked — never a plain text field for a secret.
        let secure = view.allSubviews.compactMap { $0 as? NSSecureTextField }
        XCTAssertEqual(secure.count, 1)
        XCTAssertEqual(secure.first?.placeholderString, "Secret value")

        // Exactly two actions, named by the verbs the flow uses end-to-end, with
        // Store as the Return-key default.
        let buttons = view.allSubviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(Set(buttons.map(\.title)), ["Store", "Cancel"])
        XCTAssertEqual(buttons.first { $0.title == "Store" }?.keyEquivalent, "\r")

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        print("rendered →", path.path)
    }

    func testRendersMultiFieldPrompt() {
        let (path, view) = renderToImage("secret-prompt-multi") {
            let card = SecretPromptView.make(service: "aws", account: "default", fields: [
                Field(label: "Access Key ID", masked: false),
                Field(label: "Secret Access Key", masked: true),
            ])
            // Fill in so the PNG shows the plain-vs-masked contrast and a live Store.
            card.inputs.first { $0.label == "Access Key ID" }?.field.stringValue = "AKIAIOSFODNN7EXAMPLE"
            card.inputs.first { $0.label == "Secret Access Key" }?.field.stringValue = "wJalrXUtnFEMI/bPxRfiCYEXAMPLEKEY"
            card.refreshStoreEnabled()
            return card
        }

        let texts = view.allSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains("aws / default"))
        // Both field labels render as captions.
        XCTAssertTrue(texts.contains("Access Key ID"))
        XCTAssertTrue(texts.contains("Secret Access Key"))

        // Only the secret field is masked; the shown identifier is a plain field
        // still holding its visible value.
        let secure = view.allSubviews.compactMap { $0 as? NSSecureTextField }
        XCTAssertEqual(secure.count, 1)
        let shownID = view.allSubviews.contains {
            ($0 is NSTextField) && !($0 is NSSecureTextField) && ($0 as? NSTextField)?.stringValue == "AKIAIOSFODNN7EXAMPLE"
        }
        XCTAssertTrue(shownID)

        // Both filled ⇒ Store is live.
        let store = view.allSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Store" }
        XCTAssertEqual(store?.isEnabled, true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        print("rendered →", path.path)
    }

    func testStoreDisabledUntilAllFieldsFilled() {
        let card = SecretPromptView.make(service: "aws", account: "default", fields: [
            Field(label: "Access Key ID", masked: false),
            Field(label: "Secret Access Key", masked: true),
        ])
        XCTAssertFalse(card.storeButton.isEnabled)            // empty → disabled
        card.inputs.forEach { $0.field.stringValue = "x" }
        card.refreshStoreEnabled()
        XCTAssertTrue(card.storeButton.isEnabled)             // all filled → live
        card.inputs.first?.field.stringValue = ""
        card.refreshStoreEnabled()
        XCTAssertFalse(card.storeButton.isEnabled)            // one empty → disabled again
    }
}
