import AppKit

/// The secret-entry dialog's content view, built independently of *how* it's run.
///
/// `PopupSecretInput` hosts it in a modal window for the real `add` flow, and the
/// render test rasterizes the very same view offscreen — one source of truth for
/// the UI, so the screenshot can't drift from what the user actually sees.
///
/// It renders one labelled row per `Field` (ADR-0005). A single Field with an
/// empty label is the common case and looks like a plain secret prompt. Each row's
/// input is masked unless the Field is `.show`. **Store** stays disabled until
/// every field is non-empty, so a half credential can't be written.
///
/// Visual identity (see the design plan): a brass key badge is the one spot of
/// colour on a calm graphite-on-white card; the `service / account` is shown as a
/// chip so the user can confirm *what* they're filling in. The card paints its own
/// backgrounds in `draw(_:)` (not via CALayer) so a plain `cacheDisplay` captures
/// every fill faithfully offscreen.
final class SecretPromptView: NSView, NSTextFieldDelegate {

    /// One accent (the brass key); everything else is neutral graphite/slate.
    enum Palette {
        static let ink    = NSColor(srgbRed: 0.110, green: 0.110, blue: 0.122, alpha: 1) // #1C1C1F
        static let slate  = NSColor(srgbRed: 0.431, green: 0.431, blue: 0.451, alpha: 1) // #6E6E73
        static let wash   = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1) // #F5F5F7
        static let border = NSColor(srgbRed: 0.890, green: 0.890, blue: 0.910, alpha: 1) // #E3E3E8
        static let brass  = NSColor(srgbRed: 0.659, green: 0.416, blue: 0.157, alpha: 1) // #A86A28
    }

    // Exposed so the modal controller can wire actions and read the typed values.
    // The render test only queries these (rule 4: assert on the real tree).
    let storeButton  = NSButton()
    let cancelButton = NSButton()

    /// Ordered (label → input control). `values` reads straight off these.
    private(set) var inputs: [(label: String, field: NSTextField)] = []
    var firstField: NSTextField? { inputs.first?.field }
    var values: [String: String] {
        Dictionary(uniqueKeysWithValues: inputs.map { ($0.label, $0.field.stringValue) })
    }

    private let fields: [Field]
    private let service: String
    private let account: String

    // Background frames painted in draw(_:); kept here so the fills line up exactly
    // with the subviews laid over them.
    private let badgeRect = NSRect(x: 24, y: 24, width: 44, height: 44)
    private var chipRect = NSRect.zero      // width depends on the service/account text
    private var wellRects: [NSRect] = []    // one per field
    private var storeRect = NSRect.zero
    private var cancelRect = NSRect.zero

    static func make(service: String, account: String,
                     fields: [Field] = [Field(label: "", masked: true)]) -> SecretPromptView {
        SecretPromptView(service: service, account: account, fields: fields)
    }

    init(service: String, account: String, fields: [Field]) {
        self.service = service
        self.account = account
        self.fields = fields.isEmpty ? [Field(label: "", masked: true)] : fields
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Top-left origin, so frame numbers read top-down like the layout sketch.
    override var isFlipped: Bool { true }

    // MARK: Layout

    private func build() {
        let width: CGFloat = 460, pad: CGFloat = 24, contentW = width - pad * 2

        // ── Header: brass key badge + title + service/account chip ────────────
        let key = symbol("key.fill", pointSize: 19, color: Palette.brass)
        key.frame = NSRect(x: badgeRect.minX + 10, y: badgeRect.minY + 10, width: 24, height: 24)
        addSubview(key)

        let title = label("Store a secret", size: 16, weight: .semibold, color: Palette.ink)
        title.frame = NSRect(x: 82, y: 25, width: contentW - 58, height: 22)
        addSubview(title)

        let chip = label("\(service) / \(account)", size: 12, weight: .medium, color: Palette.slate)
        chip.sizeToFit()
        chipRect = NSRect(x: 82, y: 49, width: chip.frame.width + 18, height: 22)
        chip.setFrameOrigin(NSPoint(x: chipRect.minX + 9, y: chipRect.midY - chip.frame.height / 2))
        addSubview(chip)

        // ── Instruction ───────────────────────────────────────────────────────
        let multi = fields.count > 1
        let subtitle = label(multi ? "Paste or type each value below." : "Paste or type the value below.",
                             size: 13, weight: .regular, color: Palette.slate)
        subtitle.frame = NSRect(x: pad, y: 83, width: contentW, height: 18)
        addSubview(subtitle)

        // ── One row per field ───────────────────────────────────────────────────
        var cursor: CGFloat = 112
        for field in fields {
            if !field.label.isEmpty {
                let caption = label(field.label, size: 11, weight: .semibold, color: Palette.slate)
                caption.frame = NSRect(x: pad, y: cursor, width: contentW, height: 14)
                addSubview(caption)
                cursor += 18
            }

            let well = NSRect(x: pad, y: cursor, width: contentW, height: 40)
            wellRects.append(well)

            // A masked field gets a leading lock glyph; a shown field starts flush
            // so its value is easy to eyeball against what was pasted.
            let inset: CGFloat
            if field.masked {
                let lock = symbol("lock.fill", pointSize: 13, color: Palette.slate)
                lock.frame = NSRect(x: well.minX + 14, y: well.midY - 8, width: 16, height: 16)
                addSubview(lock)
                inset = 40
            } else {
                inset = 14
            }

            let input: NSTextField = field.masked ? NSSecureTextField() : NSTextField()
            input.isBordered = false
            input.drawsBackground = false
            input.focusRingType = .none
            input.font = .systemFont(ofSize: 13)
            input.textColor = Palette.ink
            input.delegate = self
            if field.label.isEmpty { input.placeholderString = "Secret value" }
            input.frame = NSRect(x: well.minX + inset, y: well.midY - 11,
                                 width: well.width - inset - 14, height: 22)
            addSubview(input)
            inputs.append((field.label, input))

            cursor += 40 + 14   // well height + inter-row gap
        }
        cursor -= 14            // drop the trailing gap
        let fieldsBottom = cursor

        // ── Footer reassurance ──────────────────────────────────────────────────
        let shield = symbol("lock.shield", pointSize: 12, color: Palette.slate)
        shield.frame = NSRect(x: pad, y: fieldsBottom + 16, width: 14, height: 14)
        addSubview(shield)

        let footer = label("Written to your Keychain — never shown to the agent.",
                           size: 11, weight: .regular, color: Palette.slate)
        footer.frame = NSRect(x: pad + 20, y: fieldsBottom + 15, width: contentW - 20, height: 16)
        addSubview(footer)

        // ── Actions ──────────────────────────────────────────────────────────────
        let buttonY = fieldsBottom + 48
        cancelRect = NSRect(x: width - pad - 86 - 12 - 86, y: buttonY, width: 86, height: 30)
        storeRect  = NSRect(x: width - pad - 86, y: buttonY, width: 86, height: 30)
        configure(cancelButton, title: "Cancel", frame: cancelRect, titleColor: Palette.ink, key: "\u{1b}")
        configure(storeButton, title: "Store", frame: storeRect, titleColor: .white, key: "\r")
        addSubview(cancelButton)
        addSubview(storeButton)

        frame = NSRect(x: 0, y: 0, width: width, height: buttonY + 30 + 24)
        refreshStoreEnabled()
    }

    // MARK: Validation — Store is live only when every field is filled

    func controlTextDidChange(_ obj: Notification) { refreshStoreEnabled() }

    /// All fields required (ADR-0005): Store enables only when none are empty.
    func refreshStoreEnabled() {
        storeButton.isEnabled = inputs.allSatisfy { !$0.field.stringValue.isEmpty }
        needsDisplay = true   // redraw so the Store pill dims/undims with state
    }

    // MARK: Background painting

    override func draw(_ dirtyRect: NSRect) {
        fill(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), radius: 14,
             color: .white, stroke: Palette.border)
        fill(roundedRect: badgeRect, radius: 13,
             color: Palette.brass.withAlphaComponent(0.12), stroke: nil)
        fill(roundedRect: chipRect, radius: 6, color: Palette.wash, stroke: Palette.border)
        for well in wellRects {
            fill(roundedRect: well, radius: 9, color: Palette.wash, stroke: Palette.border)
        }
        fill(roundedRect: cancelRect, radius: 7, color: .white, stroke: Palette.border)
        let storeColor = storeButton.isEnabled ? Palette.ink : Palette.ink.withAlphaComponent(0.3)
        fill(roundedRect: storeRect, radius: 7, color: storeColor, stroke: nil)
    }

    private func fill(roundedRect rect: NSRect, radius: CGFloat, color: NSColor, stroke: NSColor?) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
    }

    // MARK: Builders

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImageView {
        let iv = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        iv.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iv.contentTintColor = color
        iv.imageScaling = .scaleProportionallyUpOrDown
        return iv
    }

    private func configure(_ button: NSButton, title: String, frame: NSRect,
                           titleColor: NSColor, key: String) {
        button.frame = frame
        button.title = title                 // kept plain so tests can query .title
        button.isBordered = false            // background is painted in draw(_:)
        button.focusRingType = .none
        button.keyEquivalent = key
        let para = NSMutableParagraphStyle(); para.alignment = .center
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: titleColor,
            .paragraphStyle: para,
        ])
    }
}
