import SwiftUI
import PinwheelCore

struct ProgressListView: View {
    var queue: JobQueue
    var settings: SettingsStore
    var hover: HoverTracker
    var onReveal: (Job) -> Void
    var onClose: () -> Void

    /// Lists stay readable on Crystal by using Clear Glass's light shade.
    private var level: GlassLevel { settings.glassLevel == .crystal ? .clear : settings.glassLevel }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: ProgressController.headerHeight)
            Divider().opacity(0.5)
            if queue.jobs.isEmpty {
                Text("No conversions yet. Drag files and hold ⇧ Shift.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Newest first.
                        ForEach(queue.jobs.reversed()) { job in
                            JobRow(job: job, onCancel: { queue.cancel(job) }, onReveal: { onReveal(job) })
                                .frame(height: ProgressController.rowHeight)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            Spacer(minLength: 0)
        }
        .glassSurface(level, cornerRadius: ProgressController.cornerRadius)
        .onHover { hover.isHovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(headerStyle)
                .symbolEffect(.pulse, isActive: !queue.isIdle)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if queue.jobs.contains(where: \.isDone) {
                Button("Clear") { queue.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
    }

    private var headerSymbol: String {
        if !queue.isIdle { return "arrow.triangle.2.circlepath" }
        return queue.hasFailures ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private var headerStyle: AnyShapeStyle {
        if !queue.isIdle { return AnyShapeStyle(Brand.gradient) }
        return queue.hasFailures ? AnyShapeStyle(.orange) : AnyShapeStyle(.green)
    }

    private var title: String {
        let active = queue.jobs.filter { !$0.isDone }.count
        if active > 0 { return active == 1 ? "Converting 1 file…" : "Converting \(active) files…" }
        let failed = queue.jobs.filter(\.isFailed).count
        if failed > 0 { return failed == 1 ? "1 file failed" : "\(failed) files failed" }
        return queue.jobs.isEmpty ? "Pinwheel" : "All done"
    }
}

private struct JobRow: View {
    var job: Job
    var onCancel: () -> Void
    var onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: job.icon)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(job.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("→ \(job.actionLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                status
            }
            Spacer(minLength: 4)
            trailingButton
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .waiting:
            Text("Waiting…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .running:
            // Some jobs (like GIFs, which read the whole video first) report
            // nothing for a while; show a moving bar instead of a stuck 0%.
            Group {
                if job.progress < 0.01 {
                    ProgressView()
                } else {
                    ProgressView(value: job.progress)
                }
            }
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(Brand.blue)
        case .finished:
            statusText(finishedText, color: .secondary)
        case .skipped(let reason):
            statusText(reason, color: .secondary)
        case .failed(let message):
            statusText(message, color: .red)
        case .cancelled:
            statusText("Cancelled", color: .secondary)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(text)
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch job.state {
        case .waiting, .running:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        case .finished:
            Button(action: onReveal) {
                Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 16)).foregroundStyle(Brand.blue)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(.orange)
        case .cancelled:
            EmptyView()
        }
    }

    /// "2.4 MB → 1.1 MB (−54%)", plus any note and "original in Trash".
    private var finishedText: String {
        var parts: [String] = []
        if let before = job.sourceSize, let after = job.outputSize, before > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let change = Int(((Double(after) / Double(before)) - 1) * 100)
            parts.append("\(formatter.string(fromByteCount: before)) → \(formatter.string(fromByteCount: after)) (\(change > 0 ? "+" : "")\(change)%)")
        } else if let name = job.outputs.first?.lastPathComponent {
            parts.append(name)
        }
        if let note = job.note { parts.append(note) }
        if job.originalTrashed { parts.append("Original in Trash.") }
        return parts.joined(separator: " · ")
    }
}
