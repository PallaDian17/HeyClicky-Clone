import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Markdown

/// Lightweight Markdown: fenced code blocks, bullets, headings, inline styles.
struct MarkdownText: View {
    let text: String

    private enum Block { case code(String), prose(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var inCode = false
        var buffer: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let joined = buffer.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(inCode ? .code(joined) : .prose(joined)) }
                buffer = []
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        let joined = buffer.joined(separator: "\n")
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(inCode ? .code(joined) : .prose(joined)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code)
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .textSelection(.enabled)
                case .prose(let prose):
                    ForEach(Array(prose.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        paragraphView(paragraph)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func paragraphView(_ paragraph: String) -> some View {
        let lines = paragraph.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !lines.isEmpty && lines.allSatisfy({ isBullet($0) }) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(isNumbered(line) ? String(line.trimmingCharacters(in: .whitespaces).prefix(while: { $0 != " " })) : "•")
                            .foregroundStyle(.secondary)
                        inline(stripBullet(line))
                    }
                }
            }
        } else if lines.count == 1, let heading = lines.first, heading.hasPrefix("#") {
            Text(String(heading.drop(while: { $0 == "#" || $0 == " " }))).font(.system(size: 14, weight: .semibold))
        } else {
            inline(lines.joined(separator: "\n"))
        }
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(s)
    }

    private func isBullet(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") || isNumbered(t)
    }
    private func isNumbered(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let dot = t.firstIndex(of: "."), t.distance(from: t.startIndex, to: dot) <= 3, dot > t.startIndex else { return false }
        return t[..<dot].allSatisfy(\.isNumber) && t[t.index(after: dot)...].hasPrefix(" ")
    }
    private func stripBullet(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if isNumbered(t), let dot = t.firstIndex(of: ".") { t = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces) }
        for p in ["- ", "* ", "• "] where t.hasPrefix(p) { t = String(t.dropFirst(2)) }
        return t
    }
}

// MARK: - Output column

/// Files the agent left in output/, with Quick Look preview and drag-out.
@MainActor
final class OutputFolderWatcher: ObservableObject {
    @Published private(set) var files: [URL] = []
    private var source: DispatchSourceFileSystemObject?
    private var reload: () -> [URL] = { [] }

    func watch(agent: Agent, store: AgentStore) {
        stop()
        reload = { store.outputFiles(for: agent) }
        files = reload()
        let dir = store.folder(for: agent).appendingPathComponent("output")
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.files = self.reload()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func refresh() { files = reload() }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}

struct OutputColumn: View {
    @ObservedObject var watcher: OutputFolderWatcher
    let folder: URL
    @State private var selected: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OUTPUT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("output")]) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(.borderless).help("Show in Finder")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if watcher.files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                    Text("Files it makes land here.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(watcher.files, id: \.self) { file in
                            fileCard(file)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: selected == nil ? .infinity : 180)
                if let selected {
                    Divider()
                    QuickLookPreview(url: selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func fileCard(_ file: URL) -> some View {
        let isSelected = selected == file
        return Button {
            selected = isSelected ? nil : file
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(fileMeta(file)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(file) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }

    private func fileMeta(_ file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let date = values?.contentModificationDate.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        return [size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as QLPreviewItem
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as QLPreviewItem }
    }
}

// MARK: - First-message suggestions

struct FirstMessageCards: View {
    let agent: Agent
    var onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Things to try").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(agent.firstMessages, id: \.self) { message in
                Button { onPick(message) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "bubble.left.fill").font(.caption).foregroundStyle(Color.accentColor).padding(.top, 2)
                        Text(message).font(.system(size: 13)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 560)
    }
}
