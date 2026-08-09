import SwiftUI

struct LiveOutputModePicker: View {
    @Binding var selection: LiveOutputMode
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppText.outputMode)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(AppText.outputMode, selection: $selection) {
                ForEach(LiveOutputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(isDisabled)
            .accessibilityLabel(AppText.outputMode)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}
