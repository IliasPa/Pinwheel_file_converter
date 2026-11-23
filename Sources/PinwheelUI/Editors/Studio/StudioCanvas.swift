import AppKit
import SwiftUI
import PinwheelCore

/// The picture, big, on a dark background; with the crop box or the markup
/// tools on top, depending on the tab.
struct StudioCanvas: View {
    var model: StudioModel

    /// Space around the picture: none, so it fills the window (the crop box keeps a little, to reach its edges).
    static func margin(for tab: StudioModel.Tab) -> CGFloat { tab == .crop ? 14 : 0 }
    static let background = Color(white: 0.14)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Self.background
                if let image = model.preview {
                    let rect = model.imageRect(in: geometry.size)
                    if StudioRenderer.hasAlpha(image) {
                        Checkerboard()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(model.zoom > 3 ? .none : .high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    overlay(imageRect: rect)
                } else if let error = model.loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: 360)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
                if model.showOriginal {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 10)
                }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { model.canvasSize = $0 }
            .background(ScrollAndPinch(
                onScroll: { delta in model.panBy(delta) },
                onZoomScroll: { delta, point in model.setZoom(model.zoom * exp(delta / 200), around: point) },
                onPinch: { change, point in model.setZoom(model.zoom * (1 + change), around: point) }
            ))
        }
        .clipped()
    }

    @ViewBuilder
    private func overlay(imageRect: CGRect) -> some View {
        if !model.showOriginal {
            if model.tab == .crop && model.previewTab == .crop {
                CropOverlay(model: model, imageRect: imageRect)
            } else if model.tab == .markup && model.previewTab == .markup {
                MarkupOverlay(model: model, imageRect: imageRect)
            }
        }
    }

    /// The largest rectangle with the picture's shape inside `area`, centered.
    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / size.width, area.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }
}

/// Gray and white squares behind see-through pictures.
struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.95)))
            var path = Path()
            var row = 0
            for y in stride(from: 0, to: size.height, by: square) {
                for x in stride(from: row % 2 == 0 ? 0 : square, to: size.width, by: square * 2) {
                    path.addRect(CGRect(x: x, y: y, width: square, height: square))
                }
                row += 1
            }
            context.fill(path, with: .color(Color(white: 0.8)))
        }
    }
}

/// The crop box: darkened outside, thirds lines inside, handles to drag.
private struct CropOverlay: View {
    var model: StudioModel
    let imageRect: CGRect

    private var scale: CGFloat { imageRect.width / max(model.turnedSize.width, 1) }

    private var boxRect: CGRect {
        let box = model.cropBox
        return CGRect(
            x: imageRect.minX + box.minX * scale, y: imageRect.minY + box.minY * scale,
            width: box.width * scale, height: box.height * scale
        )
    }

    var body: some View {
        let box = boxRect
        ZStack {
            Path { path in
                path.addRect(imageRect)
                path.addRect(box)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            Path { path in
                for step in 1...2 {
                    let x = box.minX + box.width * CGFloat(step) / 3
                    let y = box.minY + box.height * CGFloat(step) / 3
                    path.move(to: CGPoint(x: x, y: box.minY))
                    path.addLine(to: CGPoint(x: x, y: box.maxY))
                    path.move(to: CGPoint(x: box.minX, y: y))
                    path.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(model.isCropping ? 0.55 : 0.25), lineWidth: 0.75)

            Path { $0.addRect(box) }
                .stroke(Color.white, lineWidth: 1.5)
            Path { path in
                let arm = min(18, box.width / 3, box.height / 3)
                for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)] {
                    let dx: CGFloat = corner.x == box.minX ? arm : -arm
                    let dy: CGFloat = corner.y == box.minY ? arm : -arm
                    path.move(to: CGPoint(x: corner.x + dx, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
                }
                let mid = min(14, box.width / 4, box.height / 4)
                for (point, horizontal) in [(CGPoint(x: box.midX, y: box.minY), true), (CGPoint(x: box.midX, y: box.maxY), true),
                                            (CGPoint(x: box.minX, y: box.midY), false), (CGPoint(x: box.maxX, y: box.midY), false)] {
                    path.move(to: horizontal ? CGPoint(x: point.x - mid, y: point.y) : CGPoint(x: point.x, y: point.y - mid))
                    path.addLine(to: horizontal ? CGPoint(x: point.x + mid, y: point.y) : CGPoint(x: point.x, y: point.y + mid))
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .shadow(color: .black.opacity(0.4), radius: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !model.isCropping {
                        model.beginCrop(at: pixel(value.startLocation), tolerance: 12 / scale)
                    }
                    model.moveCrop(to: pixel(value.location))
                }
                .onEnded { _ in model.endCrop() }
        )
        .onContinuousHover { phase in
            guard case .active(let location) = phase, !model.isCropping else {
                if case .ended = phase { NSCursor.arrow.set() }
                return
            }
            Self.cursor(for: model.cropHandle(at: pixel(location), tolerance: 12 / scale)).set()
        }
    }

    /// From the view to pixels of the turned preview picture.
    private func pixel(_ location: CGPoint) -> CGPoint {
        CGPoint(x: (location.x - imageRect.minX) / scale, y: (location.y - imageRect.minY) / scale)
    }

    static func cursor(for handle: CropHandle) -> NSCursor {
        switch handle {
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .top: .frameResize(position: .top, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .right: .frameResize(position: .right, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .left: .frameResize(position: .left, directions: .all)
        case .move: .openHand
        case .new: .crosshair
        }
    }
}

/// Draws new markup, or selects and moves what's there (with no tool).
private struct MarkupOverlay: View {
    var model: StudioModel
    let imageRect: CGRect

    var body: some View {
        ZStack {
            if let frame = model.selectionFrame {
                let rect = CGRect(
                    x: imageRect.minX + frame.minX * imageRect.width, y: imageRect.minY + frame.minY * imageRect.height,
                    width: frame.width * imageRect.width, height: frame.height * imageRect.height
                )
                Path { $0.addRect(rect) }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                Path { $0.addRect(rect) }
                    .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4], dashPhase: 4.5))
            }
            if model.showsZoom, let hover = model.hover, let patch = model.zoomPatch {
                PixelLoupe(patch: patch)
                    .position(Self.loupePosition(
                        pointer: CGPoint(x: imageRect.minX + hover.x * imageRect.width, y: imageRect.minY + hover.y * imageRect.height),
                        in: imageRect.insetBy(dx: -StudioCanvas.margin(for: model.tab), dy: -StudioCanvas.margin(for: model.tab))
                    ))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // The pointer is dragging, so no hover events come: the zoom follows the drag.
                    model.hover = CGPoint(
                        x: min(max((value.location.x - imageRect.minX) / max(imageRect.width, 1), 0), 1),
                        y: min(max((value.location.y - imageRect.minY) / max(imageRect.height, 1), 0), 1)
                    )
                    if !model.isMarking { model.beginMarkup(at: point(value.startLocation)) }
                    model.continueMarkup(to: point(value.location))
                }
                .onEnded { _ in model.endMarkup() }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                model.hover = CGPoint(
                    x: min(max((location.x - imageRect.minX) / max(imageRect.width, 1), 0), 1),
                    y: min(max((location.y - imageRect.minY) / max(imageRect.height, 1), 0), 1)
                )
                if model.isPixelZoomTool {
                    NSCursor.crosshair.set()
                } else if model.tool == nil {
                    (model.annotation(at: point(location)) != nil ? NSCursor.openHand : NSCursor.arrow).set()
                } else if model.isBlurTool, let hit = model.annotation(at: point(location)), hit.kind == .redact || hit.kind == .blur {
                    NSCursor.openHand.set()  // the Blur tool picks up a blur that's there
                } else {
                    (model.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
                }
            case .ended:
                model.hover = nil
                NSCursor.arrow.set()
            }
        }
    }

    /// Beside the pointer, on whichever side has room.
    static func loupePosition(pointer: CGPoint, in area: CGRect) -> CGPoint {
        let side = PixelLoupe.side
        let height = PixelLoupe.height
        var x = pointer.x + 24 + side / 2
        var y = pointer.y - 24 - height / 2
        if x + side / 2 > area.maxX { x = pointer.x - 24 - side / 2 }
        if y - height / 2 < area.minY { y = pointer.y + 24 + height / 2 }
        return CGPoint(x: x, y: y)
    }

    private func point(_ location: CGPoint) -> RelativePoint {
        model.markupPoint(fromShown: CGPoint(
            x: (location.x - imageRect.minX) / max(imageRect.width, 1),
            y: (location.y - imageRect.minY) / max(imageRect.height, 1)
        ))
    }
}

/// A magnifier: the pixels around the pointer, each one big, with its color and place.
struct PixelLoupe: View {
    let patch: (image: CGImage, x: Int, y: Int, hex: String)

    static let side: CGFloat = 150
    static let height: CGFloat = 172

    var body: some View {
        let cells = CGFloat(StudioModel.zoomPixels)
        let cell = Self.side / cells
        VStack(spacing: 0) {
            ZStack {
                Checkerboard(square: 6)
                Image(decorative: patch.image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(patch.image.width) * cell, height: CGFloat(patch.image.height) * cell)
                Path { path in
                    for step in 0...Int(cells) {
                        let at = CGFloat(step) * cell
                        path.move(to: CGPoint(x: at, y: 0)); path.addLine(to: CGPoint(x: at, y: Self.side))
                        path.move(to: CGPoint(x: 0, y: at)); path.addLine(to: CGPoint(x: Self.side, y: at))
                    }
                }
                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .overlay(Rectangle().strokeBorder(Color.black, lineWidth: 0.75))
                    .frame(width: cell, height: cell)
                    .position(x: (CGFloat(patch.x) + 0.5) * cell, y: (CGFloat(patch.y) + 0.5) * cell)
            }
            .frame(width: Self.side, height: Self.side)
            .clipped()
            Text("\(patch.hex)")
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(.white)
                .frame(width: Self.side, height: Self.height - Self.side)
                .background(Color.black.opacity(0.8))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 6)
    }
}

/// Two-finger scrolling moves a zoomed picture; ⌘ or ⌥ with it, or a pinch,
/// zooms around the pointer. (Reads the scroll and pinch events over its
/// own area, whatever view is on top.)
struct ScrollAndPinch: NSViewRepresentable {
    /// Scrolled by this many points.
    var onScroll: (CGSize) -> Void
    /// ⌘ or ⌥ scrolling: how far, and where (in the view, y down).
    var onZoomScroll: (CGFloat, CGPoint) -> Void
    /// A pinch: the change in size (0.1 = 10% bigger), and where.
    var onPinch: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.owner = self
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.owner = self }

    final class CatcherView: NSView {
        var owner: ScrollAndPinch?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, let owner else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            switch event.type {
            case .magnify:
                owner.onPinch(event.magnification, point)
            case .scrollWheel:
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
                if !event.modifierFlags.intersection([.command, .option]).isEmpty {
                    owner.onZoomScroll(event.scrollingDeltaY * scale, point)
                } else {
                    owner.onScroll(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
                }
            default:
                return false
            }
            return true
        }
    }
}
