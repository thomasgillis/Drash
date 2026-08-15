import SwiftUI

struct AlertDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let alert: WeatherAlert

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(alert.severity, systemImage: alert.symbolName)
                        .font(.headline).foregroundStyle(alert.severityColor)

                    Text(alert.headline ?? alert.event).font(.title2.bold())

                    LabeledContent("Area", value: alert.areaDescription)
                    if let onset = alert.onset {
                        LabeledContent("Begins", value: onset.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let expires = alert.ends ?? alert.expires {
                        LabeledContent("Ends", value: expires.formatted(date: .abbreviated, time: .shortened))
                    }

                    Divider()
                    Text(alert.description).textSelection(.enabled)

                    if let instruction = alert.instruction, !instruction.isEmpty {
                        GroupBox("What to do") {
                            Text(instruction).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Text("Issued by \(alert.senderName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(alert.event)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
