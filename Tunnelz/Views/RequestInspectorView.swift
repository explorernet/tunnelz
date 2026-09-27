import SwiftUI

struct RequestInspectorView: View {
    let request: CapturedRequest?
    let tunnel: Tunnel?
    let publicURL: URL?
    let canReplay: Bool
    let onReplay: (CapturedRequest) -> Void
    let onReplayEdited: (ReplayRequestDraft) -> Void
    let onToggleSaved: (CapturedRequest) -> Void
    @State private var tab = "Request"
    @State private var headersExpanded = false
    @State private var bodyExpanded = true
    @State private var showsAllHeaders = false
    @State private var headersContentHeight: CGFloat = 0
    @State private var replayDraft: ReplayRequestDraft?

    var body: some View {
        if let request {
            VStack(alignment: .leading, spacing: 0) {
                inspectorHeader(for: request)
                GlassTabs(selection: $tab, tabs: ["Request", "Response", "Overview"])
                .padding(.vertical, 4)
                .padding(.horizontal, 16)
                if tab == "Overview" {
                    ScrollView {
                        section("General") {
                            LabeledContent("Method", value: request.method)
                            LabeledContent("URL", value: requestURL(path: request.path))
                            LabeledContent("Status", value: String(request.status))
                            LabeledContent("Duration", value: request.duration)
                            LabeledContent("Time", value: request.time)
                        }
                        .padding(16)
                    }
                } else {
                    // Not in a ScrollView, so the body viewer can take the remaining height.
                    exchangeDetails(
                        title: tab,
                        headers: tab == "Request" ? request.requestHeaders : request.responseHeaders,
                        body: tab == "Request" ? request.requestBody : request.responseBody
                    )
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                Divider()
                inspectorFooter(for: request)
            }
            .onChange(of: request.id) {
                showsAllHeaders = false
                headersExpanded = false
            }
            .onChange(of: tab) {
                showsAllHeaders = false
                headersExpanded = false
            }
            .sheet(item: $replayDraft) { draft in
                EditReplayView(draft: draft, onReplay: onReplayEdited)
            }
        } else {
            ContentUnavailableView("No Request Selected", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func requestURL(path: String) -> String {
        if let publicURL {
            return publicURL.appending(path: path).absoluteString
        }
        return "http://\(tunnel?.localURL ?? "localhost")\(path)"
    }

    private func exchangeDetails(title: String, headers: [CapturedHeader], body: Data) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                disclosureButton(isExpanded: $headersExpanded) {
                    disclosureLabel("\(title) Headers", metadata: String(headers.count))
                }
                if headersExpanded {
                    Divider()
                        .padding(.vertical, 8)
                    // Sized to its content up to a cap, then scrolls, so the body keeps its space.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { headerRows(headers) }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                headersContentHeight = $0
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(headersContentHeight, 260))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                disclosureButton(isExpanded: $bodyExpanded) {
                    disclosureLabel(
                        "\(title) Body",
                        metadata: byteCount(body.count),
                        trailing: contentType(in: headers)
                    )
                }
                if bodyExpanded {
                    Divider()
                        .padding(.vertical, 8)
                    bodyViewer(body, contentType: contentType(in: headers))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxHeight: bodyExpanded ? .infinity : nil, alignment: .top)
        }
    }

    private func disclosureButton<Label: View>(
        isExpanded: Binding<Bool>,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .frame(width: 12)
                label()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func disclosureLabel(_ title: String, metadata: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func headerRows(_ headers: [CapturedHeader]) -> some View {
        if headers.isEmpty {
            Text("No headers")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let sortedHeaders = headers.sorted(by: headerSort)
            let visibleHeaders = showsAllHeaders ? sortedHeaders : Array(sortedHeaders.prefix(5))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(Array(visibleHeaders.enumerated()), id: \.offset) { _, header in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(header.name)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(header.value)
                            .textSelection(.enabled)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)

            if headers.count > 5 {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsAllHeaders.toggle()
                    }
                } label: {
                    Label(
                        showsAllHeaders ? "Show fewer headers" : "Show all \(headers.count) headers",
                        systemImage: showsAllHeaders ? "chevron.up" : "chevron.down"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.top, 5)
            }
        }
    }

    private func headerSort(_ lhs: CapturedHeader, _ rhs: CapturedHeader) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func contentType(in headers: [CapturedHeader]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare("content-type") == .orderedSame }?
            .value.split(separator: ";", maxSplits: 1).first.map(String.init)
    }

    private func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func bodyText(_ data: Data) -> String {
        guard !data.isEmpty else { return "No body" }
        if let pretty = prettyJSON(data) { return pretty }
        return String(data: data, encoding: .utf8) ?? "Binary body · \(data.count) bytes"
    }

    @ViewBuilder
    private func bodyViewer(_ data: Data, contentType: String?) -> some View {
        if contentType?.lowercased().hasPrefix("image/") == true, let image = NSImage(data: data) {
            imageViewer(image)
        } else if let json = prettyJSON(data) {
            JSONCodeView(text: .constant(json), fillsHeight: true)
        } else {
            ScrollView {
                codeBlock(bodyText(data))
            }
        }
    }

    /// Shown at its natural size (never upscaled) on a checkerboard so transparency is visible.
    private func imageViewer(_ image: NSImage) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .background(CheckerboardBackground())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .background(JSONCodeView.editorBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
    }

    private func prettyJSON(_ data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: prettyData, encoding: .utf8)
    }

    private func inspectorHeader(for request: CapturedRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                HTTPMethodBadge(method: request.method)
                Text(request.path)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Text(String(request.status))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor(for: request.status))

                Divider().frame(height: 14)

                compactMetric(dateLabel(for: request.startedAt), systemImage: "clock")
                Divider().frame(height: 14)
                compactMetric(request.duration, systemImage: "timer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactMetric(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
        }
    }

    private func dateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today at \(timeLabel(for: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at \(timeLabel(for: date))"
        }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(timeLabel(for: date))"
    }

    private func timeLabel(for date: Date) -> String {
        date.formatted(
            .dateTime
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    private func inspectorFooter(for request: CapturedRequest) -> some View {
        // Labels collapse to icons when the inspector is narrow.
        ViewThatFits(in: .horizontal) {
            footerButtons(for: request, iconsOnly: false)
            footerButtons(for: request, iconsOnly: true)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func footerButtons(for request: CapturedRequest, iconsOnly: Bool) -> some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)
            Button(
                request.isSaved ? "Saved" : "Save",
                systemImage: request.isSaved ? "bookmark.fill" : "bookmark"
            ) {
                onToggleSaved(request)
            }
            .help(request.isSaved ? "Remove from saved requests" : "Save this request")
            Button("Copy as cURL", systemImage: "doc.on.doc") {
                Pasteboard.copy(CURLCommand.make(for: request, publicURL: publicURL, localURL: tunnel?.localURL))
            }
            .labelStyle(iconsOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleOnly))
            .help("Copy as cURL")
            Button("Edit & Replay", systemImage: "square.and.pencil") {
                replayDraft = ReplayRequestDraft(request: request)
            }
            .labelStyle(iconsOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleOnly))
            .help("Edit & Replay")
            .disabled(!canReplay)
            Button("Replay", systemImage: "arrow.clockwise") {
                onReplay(request)
            }
            .help("Replay")
            .disabled(!canReplay)
            .buttonStyle(.borderedProminent)
        }
        .labelStyle(iconsOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        .fixedSize(horizontal: iconsOnly ? false : true, vertical: false)
    }

    private func statusColor(for status: Int) -> Color {
        switch status {
        case 100..<300: .green
        case 300..<400: .orange
        default: .red
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(JSONCodeView.editorBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
    }
}



/// Capsule tab switcher in Liquid Glass, spanning the available width.
private struct GlassTabs: View {
    @Binding var selection: String
    let tabs: [String]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    Text(tab)
                        .fontWeight(.medium)
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
