#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// A native responder owns selection and Copy; unrelated SwiftUI updates leave its range intact.
struct DesktopSelectableText: UIViewRepresentable {
    let text: AttributedString
    let identity: String
    var size: CGFloat = 16
    var weight: UIFont.Weight = .regular
    var secondary = false
    var lineSpacing: CGFloat = 5

    func makeUIView(context: Context) -> DesktopReaderTextView { DesktopReaderTextView() }

    func updateUIView(_ view: DesktopReaderTextView, context: Context) {
        view.display(text, identity: identity, size: size, weight: weight, secondary: secondary, lineSpacing: lineSpacing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DesktopReaderTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

final class DesktopReaderTextView: UITextView, UITextViewDelegate {
    private var sourceIdentity: String?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        delegate = self
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeFirstResponder: Bool { true }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if selectedRange.length > 0, !isFirstResponder { becomeFirstResponder() }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selectedRange.length > 0 && NSMaxRange(selectedRange) <= (text as NSString).length }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0, NSMaxRange(selectedRange) <= (text as NSString).length else { return }
        UIPasteboard.general.string = (text as NSString).substring(with: selectedRange)
    }

    func display(_ body: AttributedString, identity: String, size: CGFloat, weight: UIFont.Weight,
                 secondary: Bool, lineSpacing: CGFloat) {
        let value = NSMutableAttributedString(body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        value.addAttributes([.font: UIFont.systemFont(ofSize: size, weight: weight),
                             .foregroundColor: secondary ? UIColor.secondaryLabel : UIColor.label,
                             .paragraphStyle: paragraph], range: NSRange(location: 0, length: value.length))
        let sameSource = sourceIdentity == identity
        guard !sameSource || attributedText != value else { return }
        let selection = selectedRange
        let sameText = text == value.string
        sourceIdentity = identity
        attributedText = value
        if sameSource, sameText, NSMaxRange(selection) <= value.length { selectedRange = selection }
        else { selectedRange = NSRange(location: 0, length: 0) }
        accessibilityIdentifier = identity
        invalidateIntrinsicContentSize()
    }
}
#endif
