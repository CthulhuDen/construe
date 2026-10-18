import SwiftUI

/// Content of the quick panel: the input field and the streamed response below it.
struct QuickView: View {
    @Bindable var session: TranslationSession
    var openSettings: () -> Void

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
        .onAppear { isInputFocused = true }
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
                    Text(session.response)
                        .textSelection(.enabled)
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
