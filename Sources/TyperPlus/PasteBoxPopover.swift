import AppKit

/// The menu-bar popover: paste text, pick a mode, hit "Type this". On type it
/// hands the text to the controller, which runs the countdown then types it into
/// whatever field the user focuses.
final class PasteBoxViewController: NSViewController {

    var onType: ((String) -> Void)?
    var onModeChange: ((TypingProfile.Mode) -> Void)?

    private var textView: NSTextView!
    private var modePopup: NSPopUpButton!
    private var subtitle: NSTextField!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))

        let title = NSTextField(labelWithString: "Paste text to type")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 16, y: 286, width: 388, height: 20)
        root.addSubview(title)

        // Paste box (plain text, scrollable).
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 96, width: 388, height: 182))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        let tv = NSTextView(frame: scroll.bounds)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.isEditable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false   // keep the user's exact text
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        scroll.documentView = tv
        root.addSubview(scroll)
        textView = tv

        // Mode picker.
        let modeLabel = NSTextField(labelWithString: "Mode:")
        modeLabel.frame = NSRect(x: 16, y: 60, width: 44, height: 20)
        root.addSubview(modeLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 60, y: 56, width: 180, height: 26))
        popup.addItems(withTitles: TypingProfile.Mode.allCases.map { $0.rawValue })
        popup.selectItem(withTitle: Settings.shared.mode.rawValue)
        popup.target = self
        popup.action = #selector(modeChanged)
        root.addSubview(popup)
        modePopup = popup

        let sub = NSTextField(labelWithString: TypingProfile.preset(Settings.shared.mode).mode.subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 16, y: 36, width: 388, height: 16)
        root.addSubview(sub)
        subtitle = sub

        let typeButton = NSButton(title: "Type this", target: self, action: #selector(typeTapped))
        typeButton.bezelStyle = .rounded
        typeButton.keyEquivalent = "\r"
        typeButton.frame = NSRect(x: 300, y: 52, width: 104, height: 32)
        root.addSubview(typeButton)

        let hint = NSTextField(labelWithString: "Click Type, then click your target field during the countdown. Stop: Esc Esc Esc.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 16, y: 10, width: 388, height: 26)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        root.addSubview(hint)

        self.view = root
        preferredContentSize = root.frame.size
    }

    /// Focus the text box when the popover appears.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        refreshSubtitle()
    }

    @objc private func modeChanged() {
        guard let title = modePopup.titleOfSelectedItem,
              let mode = TypingProfile.Mode(rawValue: title) else { return }
        onModeChange?(mode)
        refreshSubtitle()
    }

    private func refreshSubtitle() {
        subtitle.stringValue = Settings.shared.mode.subtitle
        modePopup.selectItem(withTitle: Settings.shared.mode.rawValue)
    }

    @objc private func typeTapped() {
        let text = textView.string
        guard !text.isEmpty else { return }
        onType?(text)
    }
}
