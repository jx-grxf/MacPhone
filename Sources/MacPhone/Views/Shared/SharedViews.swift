import SwiftUI
import AppKit

/// Symbol and word, never colour alone.
struct StatusLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Monospaced output of a running job, following the newest line.
struct LogView: View {
    let lines: [String]
    var minHeight: CGFloat = 140

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(Design.Space.s)
            }
            .frame(minHeight: minHeight)
            .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous).strokeBorder(Design.separator))
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

/// The outcome of the last action, pinned above the content until dismissed.
struct NoticeBar: View {
    let notice: DeviceStore.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? .orange : .green)
            Text(notice.message)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: Design.Space.s)
            if let url = notice.revealURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Space.s)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A grouped block of rows, the way System Settings draws them.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.separator.opacity(0.6)))
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
