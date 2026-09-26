import AppKit
import SwiftUI

struct JSONCodeView: View {
    @Binding var text: String
    var isEditable = false
    /// Takes all the height offered and scrolls inside, instead of sizing to the content.
    var fillsHeight = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            JSONTextView(text: $text, isEditable: isEditable)
                .frame(height: fillsHeight ? nil : editorHeight)
                .frame(maxHeight: fillsHeight ? .infinity : nil)

            Button {
                Pasteboard.copy(text)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .padding(8)
            .help("Copy JSON")
            .accessibilityLabel("Copy JSON")
        }
        .background(Self.editorBackground, in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.separator)
        }
    }

    /// A shade darker than the window in dark mode, so it reads as a well without going pure black.
    static let editorBackground = Color(nsColor: NSColor(name: nil) { appearance in
        guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return .textBackgroundColor }
        return NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1)
    })

    private var editorHeight: CGFloat {
        let lineCount = text.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        return min(max(CGFloat(lineCount) * 17 + 20, 84), 360)
    }
}

private struct JSONTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        context.coordinator.render(text, in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        context.coordinator.text = $text

        if textView.string != text {
            context.coordinator.render(text, in: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var isRendering = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isRendering, let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            render(textView.string, in: textView)
        }

        func render(_ value: String, in textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            isRendering = true
            textView.textStorage?.setAttributedString(JSONSyntaxHighlighter.highlight(value))
            textView.selectedRanges = selectedRanges
            isRendering = false
        }
    }
}

private enum JSONSyntaxHighlighter {
    static func highlight(_ source: String) -> NSAttributedString {
        let fullRange = NSRange(source.startIndex..., in: source)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2

        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        color(pattern: #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, in: source, range: fullRange, color: .systemOrange, result: result)
        color(pattern: #"\b(?:true|false)\b"#, in: source, range: fullRange, color: .systemPurple, result: result)
        color(pattern: #"\bnull\b"#, in: source, range: fullRange, color: .secondaryLabelColor, result: result)

        guard let stringExpression = try? NSRegularExpression(pattern: #"\"(?:\\.|[^\"\\])*\""#) else {
            return result
        }

        let nsSource = source as NSString
        for match in stringExpression.matches(in: source, range: fullRange) {
            let suffixStart = NSMaxRange(match.range)
            let suffix = nsSource.substring(from: suffixStart)
            let isKey = suffix.first { !$0.isWhitespace } == ":"
            result.addAttribute(
                .foregroundColor,
                value: isKey ? NSColor.systemBlue : NSColor.systemGreen,
                range: match.range
            )
        }

        return result
    }

    private static func color(
        pattern: String,
        in source: String,
        range: NSRange,
        color: NSColor,
        result: NSMutableAttributedString
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        for match in expression.matches(in: source, range: range) {
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
