import SwiftUI
import PinwheelCore

struct ProgressListView: View {
    @ObservedObject var queue: JobQueue
    @ObservedObject var settings: SettingsStore
    @ObservedObject var hover: HoverTracker
    var onReveal: (Job) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: ProgressController.headerHeight)
            Divider().opacity(0.6)
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
        .background(GlassSurface(level: settings.glassLevel.effective, cornerRadius: ProgressPanel.cornerRadius))
        .onHover { hover.isHovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: queue.isIdle ? (queue.hasFailures ? "exclamationmark.circle.fill" : "checkmark.circle.fill") : "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(queue.isIdle ? (queue.hasFailures ? AnyShapeStyle(.orange) : AnyShapeStyle(.green)) : AnyShapeStyle(Brand.gradient))
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

    private var title: String {
        let active = queue.jobs.filter { !$0.isDone }.count
        if active > 0 { return active == 1 ? "Converting 1 file…" : "Converting \(active) files…" }
        let failed = queue.jobs.filter(\.isFailed).count
        if failed > 0 { return failed == 1 ? "1 file failed" : "\(failed) files failed" }
        return queue.jobs.isEmpty ? "Pinwheel" : "All done"
    }
}

private struct JobRow: View {
    @ObservedObject var job: Job
    var onCancel: () -> Void
    var onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: job.icon)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(job.file.url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("→ \(job.action.title(in: .tools))")
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
            Text(finishedText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        case .cancelled:
            Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
        }
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
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(.orange)
        case .cancelled:
            EmptyView()
        }
    }

    private var finishedText: String {
        let name = job.outputs.first?.lastPathComponent ?? "Done"
        guard let after = job.outputSize else { return name }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if case .tool(.compress) = job.action, let before = job.sourceSize, before > 0 {
            let change = Int(((Double(after) / Double(before)) - 1) * 100)
            return "\(formatter.string(fromByteCount: before)) → \(formatter.string(fromByteCount: after)) (\(change > 0 ? "+" : "")\(change)%)"
        }
        return "\(name) · \(formatter.string(fromByteCount: after))"
    }
}
