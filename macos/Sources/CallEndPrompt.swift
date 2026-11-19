import AppKit
import SwiftUI

/// "The call seems to be over": a small panel at the top right of the screen, over every app and
/// Space, that stays until Stop Recording or Keep Recording is clicked (or people talk again).
/// It does not take the keyboard from the app in front.
@MainActor
final class CallEndPrompt {
    private var panel: NSPanel?

    nonisolated init() {}

    func show(stop: @escaping () -> Void, keep: @escaping () -> Void) {
        hide()
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let view = NSHostingView(rootView: CallEndView(
            stop: { [weak self] in self?.hide(); stop() },
            keep: { [weak self] in self?.hide(); keep() }))
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - panel.frame.width - 12, y: area.maxY - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Takes clicks without bringing Claude Whisper to the front.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

private struct CallEndView: View {
    let stop: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("The call seems to be over").font(.headline)
            }
            Text("Nobody has spoken for a minute, or the call app let go of the microphone. Stop the note?")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep Recording", action: keep)
                Button("Stop Recording", action: stop).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
