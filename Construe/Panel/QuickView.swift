import SwiftUI
import Textual

/// Content of the quick panel: the input field and the streamed response below it.
struct QuickView: View {
    @Bindable var session: TranslationSession
    var openSettings: () -> Void
    /// Reports the content's natural height so the panel can be resized to fit.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @FocusState private var isInputFocused: Bool
    @State private var responseHeight: CGFloat = 0

    /// The response area grows with its content up to this height, then scrolls.
    private static let maxResponseHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Type or paste text…", text: $session.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .onSubmit(session.send)
                if session.phase == .streaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(16)

            if showsResponseArea {
                Divider()
                responseArea
            }
        }
        .frame(width: PanelController.panelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        // Keep the content pinned to the top while the panel catches up with a new height.
        .frame(maxHeight: .infinity, alignment: .top)
        .defaultFocus($isInputFocused, true)
        // The panel becomes key right after the view appears; focusing a turn later makes it stick.
        .onAppear { DispatchQueue.main.async { isInputFocused = true } }
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
