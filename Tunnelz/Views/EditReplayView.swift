import SwiftUI

struct EditReplayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReplayRequestDraft
    @State private var headersExpanded = false
    @State private var bodyExpanded = true
    let onReplay: (ReplayRequestDraft) -> Void

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    init(draft: ReplayRequestDraft, onReplay: @escaping (ReplayRequestDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onReplay = onReplay
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Edit & Replay")
                    .font(.title2.weight(.semibold))
                Text("Modify this request and send it through the tunnel again.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Method").font(.headline)
                            Picker("Method", selection: $draft.method) {
                                ForEach(methods, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Path").font(.headline)
                            TextField("/api/resource", text: $draft.path)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    DisclosureGroup(isExpanded: $headersExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $draft.headersText)
                                .font(.system(.caption, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(height: 180)
                                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
                            Text("One header per line, in Name: Value format.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    } label: {
                        disclosureLabel("Headers", metadata: "\(draft.headers.count)")
                    }

                    DisclosureGroup(isExpanded: $bodyExpanded) {
                        if draft.isJSON {
                            JSONCodeView(text: $draft.body, isEditable: true)
                                .padding(.top, 8)
                        } else {
                            TextEditor(text: $draft.body)
                                .font(.system(.caption, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 150)
                                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
                                .padding(.top, 8)
                        }
                    } label: {
                        disclosureLabel(
                            "Body",
                            metadata: ByteCountFormatter.string(
                                fromByteCount: Int64(draft.body.utf8.count),
                                countStyle: .file
                            )
                        )
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replay", systemImage: "arrow.clockwise") {
                    onReplay(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 680, height: 650)
    }

    private func disclosureLabel(_ title: String, metadata: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
