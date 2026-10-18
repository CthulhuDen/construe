import KeyboardShortcuts
import SwiftUI
import Textual

/// Content of the quick panel: the input field and the streamed response below it.
struct QuickView: View {
    @Bindable var session: TranslationSession
    /// Whether a region has been grabbed before, so Re-grab has something to capture.
    var canRegrab = false
    var grabRegion: () -> Void = {}
    var regrabRegion: () -> Void = {}
    var openSettings: () -> Void
    /// Opens the handoff link and closes the panel.
    var continueInClaude: (URL) -> Void = { _ in }
    /// Reports the content's natural height so the panel can be resized to fit.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @State private var responseHeight: CGFloat = 0

    /// The response area grows with its content up to this height, then scrolls.
    private static let maxResponseHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                InputTextView(
                    text: $session.input,
                    placeholder: "Type, paste text or a screenshot…",
                    onSubmit: session.send,
                    onPasteImage: { image in
                        Task { await session.attachImage(image) }
                    }
                )
                if session.phase == .streaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(16)

            captureRow
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            if session.imagePNG != nil || session.imageNotice != nil {
                imageRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if showsResponseArea {
                Divider()
                responseArea
            }
        }
        .frame(width: PanelController.panelWidth)
        // Always take the natural height, whatever the window's current height. Otherwise flexible
        // content (the screenshot thumbnail) shrinks while the panel lags behind a size change,
        // and the smaller measurement feeds back into the panel height, making it bounce.
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        // Keep the content pinned to the top while the panel catches up with a new height.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Buttons that read text from a screen region, with their (changeable) panel shortcuts.
    private var captureRow: some View {
        HStack(spacing: 16) {
            captureButton("Grab region", systemImage: "rectangle.dashed", shortcut: .grabRegion, action: grabRegion)
            captureButton("Re-grab", systemImage: "arrow.clockwise", shortcut: .regrabRegion, action: regrabRegion)
                .disabled(!canRegrab)
            Spacer()
        }
        .font(.callout)
    }

    private func captureButton(
        _ title: LocalizedStringKey, systemImage: String, shortcut name: KeyboardShortcuts.Name,
        action: @escaping () -> Void
    ) -> some View {
        let shortcut = name.shortcut
        return Button(action: action) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                if let shortcut {
                    Text(shortcut.description)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut?.toSwiftUI)
    }

    /// Thumbnail of the pasted screenshot with its status and a remove button.
    private var imageRow: some View {
        HStack(spacing: 10) {
            if let png = session.imagePNG, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 120, maxHeight: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Group {
                if session.isReadingImage {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading text…")
                    }
                } else if let notice = session.imageNotice {
                    Text(notice)
                } else if !session.sendsImage {
                    Text("Text only; the image isn't sent (see Settings).")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Remove screenshot", systemImage: "xmark.circle.fill", action: session.removeImage)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private var showsResponseArea: Bool {
        session.phase == .streaming || !session.response.isEmpty || !session.notices.isEmpty || isFailed
    }

    private var isFailed: Bool {
        if case .failed = session.phase { true } else { false }
    }

    private var responseArea: some View {
        // A ScrollView has no natural height, so measure the content and size the scroll view to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Thinking models can take a few seconds before the first token; show that something is happening.
                if session.phase == .streaming && session.response.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for Claude…")
                            .foregroundStyle(.secondary)
                    }
                }
                if !session.response.isEmpty {
                    // Re-parsed on every streamed chunk; responses are short, so this stays cheap.
                    StructuredText(markdown: session.response)
                        .textual.textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let url = session.handoffURL {
                    HStack {
                        Spacer()
                        Button("Continue in Claude", systemImage: "arrow.up.forward.app") {
                            continueInClaude(url)
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Open a new claude.ai chat prefilled with this exchange (⌘↩)")
                    }
                }
                ForEach(session.notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if case let .failed(message) = session.phase {
                    HStack {
                        Label(message, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Open Settings", action: openSettings)
                    }
                }
            }
            .padding(16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { responseHeight = $0 }
        }
        .frame(height: min(responseHeight, Self.maxResponseHeight))
    }
}

#Preview {
    QuickView(session: TranslationSession(settings: AppSettings(defaults: UserDefaults(suiteName: "preview") ?? .standard)), openSettings: {})
}

#Preview("Markdown response") {
    StructuredText(markdown: """
        [Me](https://www.fbbva.es/diccionario/yo) [he](https://www.fbbva.es/diccionario/haber) \
        [liado](https://www.fbbva.es/diccionario/liar) un poco.

        Translation: I've messed up a bit.
        - **liarse** (colloquial): to get muddled, to mess something up.
        - *he liado*: present perfect, common in Spain for recent past actions.
        """)
        .textual.textSelection(.enabled)
        .padding(16)
        .frame(width: PanelController.panelWidth, alignment: .leading)
}
