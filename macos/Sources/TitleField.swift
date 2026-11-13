import AppKit
import SwiftUI

/// The note's title: a borderless, wrapping text field as tall as its lines. SwiftUI's TextField
/// clips a large font that wraps (while editing it shows one line), so this is an NSTextView
/// that SwiftUI asks for its height.
struct TitleField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    /// Whether it is being edited; it ends with Return, Escape or a click elsewhere.
    @Binding var editing: Bool

    func makeNSView(context: Context) -> TitleTextView {
        let view = TitleTextView()
        view.delegate = context.coordinator
        view.font = font
        view.placeholder = placeholder
        view.string = text
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        return view
    }

    func updateNSView(_ view: TitleTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text, !view.isEditing { view.string = text }
        view.font = font
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TitleTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TitleField

        init(_ parent: TitleField) { self.parent = parent }

        func textDidBeginEditing(_ notification: Notification) { parent.editing = true }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TitleTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }

        func textDidEndEditing(_ notification: Notification) { parent.editing = false }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Return and Escape finish editing; a title has no line breaks of its own.
            guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:))
            else { return false }
            textView.window?.makeFirstResponder(nil)
            return true
        }
    }
}

final class TitleTextView: NSTextView {
    var placeholder = ""
    private(set) var isEditing = false

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer, let font else { return 30 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: font)
        return ceil(max(layout.usedRect(for: container).height, lineHeight))
    }

    override func becomeFirstResponder() -> Bool {
        isEditing = super.becomeFirstResponder()
        needsDisplay = true
        return isEditing
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isEditing = false
            setSelectedRange(NSRange(location: 0, length: 0))
            needsDisplay = true
        }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font else { return }
        (placeholder as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }
}
