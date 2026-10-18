import SwiftUI

/// Content of the quick panel. For now a single input field, used to validate focus and dismiss behaviour.
struct QuickView: View {
    @State private var input = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        TextField("Type or paste text…", text: $input)
            .textFieldStyle(.plain)
            .font(.title2)
            .focused($isInputFocused)
            .padding(16)
            .frame(width: PanelController.panelWidth)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .onAppear { isInputFocused = true }
    }
}

#Preview {
    QuickView()
}
