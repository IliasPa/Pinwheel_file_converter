import AppKit
import Observation
import PinwheelCore

/// Everything the image editor shows and does. It edits a smaller copy of
/// the picture for speed; Save sends the edit to a job, which draws it again
/// at full size with the same code (so the saved file matches the preview).
@Observable
final class StudioModel {
    enum Tab: String, CaseIterable, Identifiable {
        case crop, adjust, background, markup, watermark

        var id: Self { self }

        init(_ editor: Editor) {
            switch editor {
            case .adjust: self = .adjust
            case .background: self = .background
            case .markup: self = .markup
            case .watermark: self = .watermark
            default: self = .crop
            }
        }

        var title: String {
            switch self {
            case .crop: "Crop"
            case .adjust: "Adjust"
            case .background: "Background"
            case .markup: "Markup"
            case .watermark: "Watermark"
            }
        }

        var symbolName: String {
            switch self {
            case .crop: "crop"
            case .adjust: "slider.horizontal.3"
            case .background: "photo.artframe"
            case .markup: "pencil.tip.crop.circle"
            case .watermark: "signature"
            }
        }
    }

    enum SubjectState: Equatable {
        case idle, finding, found, notFound
        /// No subject, but the plain background could be removed instead.
        case plainBackground
        case failed(String)
    }

    /// Line widths and text sizes, as a share of the picture's longer side.
    enum StrokeSize: String, CaseIterable, Identifiable {
        case small, medium, large

        var id: Self { self }
        var title: String { rawValue.prefix(1).uppercased() }

        func share(for kind: Annotation.Kind) -> Double {
            let steps: (Double, Double, Double) = switch kind {
            case .text: (0.035, 0.05, 0.075)
            case .number: (0.04, 0.055, 0.08)
            case .highlighter: (0.02, 0.03, 0.045)
            default: (0.004, 0.007, 0.012)
            }
            return switch self {
            case .small: steps.0
            case .medium: steps.1
            case .large: steps.2
            }
        }
    }

    /// The editor works on a copy at most this many pixels long.
    nonisolated static let previewSize = 1800

    let files: [SourceFile]
    var index = 0 {
        didSet { if index != oldValue { load() } }
    }
    var tab: Tab {
        didSet {
            guard tab != oldValue else { return }
            selection = nil
            draft = nil
            scheduleRender()
        }
    }
    private(set) var edit = ImageEdit()

    // The picture shown
    private(set) var source: StudioSource?
    private(set) var loadError: String?
    private(set) var renderError: String?
    private(set) var preview: CGImage?
    /// Which tab `preview` was drawn for (it lags a moment behind `tab`).
    private(set) var previewTab: Tab?
    private(set) var subject = SubjectState.idle
    private(set) var filterThumbnails: [PhotoFilter: CGImage] = [:]
    /// While the Compare button is held.
    var showOriginal = false {
        didSet { if showOriginal != oldValue { scheduleRender() } }
    }

    // Markup
    var tool: Annotation.Kind? = .arrow
    private(set) var color = MarkupColor.red
    private(set) var strokeSize = StrokeSize.medium
    var selection: UUID?
    /// What the Text tool places next.
    private(set) var pendingText = "Text"
    private(set) var draft: Annotation?
    private(set) var isMarking = false
    private(set) var isCropping = false

    // Undo
    let undoManager = UndoManager()
    /// Goes up with every undoable change, so the Undo buttons refresh.
    private(set) var history = 0

    var onSave: ((ImageEdit) -> Void)?
    var onClose: (() -> Void)?

    @ObservationIgnored private var mask: CGImage?
    @ObservationIgnored private var cache: (key: CacheKey, content: StudioContent)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderAgain = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var subjectTask: Task<Void, Never>?
    @ObservationIgnored private var cropDrag: (handle: CropHandle, rect: CGRect, start: CGPoint)?
    @ObservationIgnored private var moveDrag: (id: UUID, start: RelativePoint, points: [RelativePoint])?
    /// A drag records its undo step only once it actually changes something.
    @ObservationIgnored private var gestureNeedsCheckpoint = false
    @ObservationIgnored private var textBeingTyped: UUID?

    private struct CacheKey: Equatable {
        var edit: ImageEdit
        var hasMask: Bool
    }

    /// `watermark` is the last one used; opening on the Watermark tab starts with it.
    init(files: [SourceFile], tab: Tab, watermark: Watermark? = nil) {
        self.files = files
        self.tab = tab
        lastWatermark = watermark
        undoManager.levelsOfUndo = 200
        if tab == .watermark { edit.watermark = watermark ?? Watermark() }
        load()
    }

    /// Offered again when a watermark is switched on.
    @ObservationIgnored private let lastWatermark: Watermark?

    var file: SourceFile { files[index] }

    // MARK: - Changing the edit (undoable)

    /// Remembers the edit so Undo can bring it back. Call before changing it.
    func checkpoint() {
        registerUndo(back: edit)
        textBeingTyped = nil
    }

    private func restore(_ old: ImageEdit) {
        registerUndo(back: edit)  // while undoing, this becomes the redo
        apply(old)
        if let selection, !old.markup.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// Each change is its own undo step. The undo manager normally groups by
    /// event, closing groups as the run loop turns; changes made outside an
    /// event (from a task) get a group of their own.
    private func registerUndo(back state: ImageEdit) {
        let ownGroup = undoManager.groupingLevel == 0
        if ownGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(state) }
        }
        if ownGroup { undoManager.endUndoGrouping() }
        history += 1
    }

    /// One undoable change.
    func change(_ body: (inout ImageEdit) -> Void) {
        var copy = edit
        body(&copy)
        guard copy != edit else { return }
        checkpoint()
        apply(copy)
    }

    /// A change while a slider or drag moves; `checkpoint()` was called when it started.
    func update(_ body: (inout ImageEdit) -> Void) {
        var copy = edit
        body(&copy)
        if gestureNeedsCheckpoint && copy != edit {
            checkpoint()
            gestureNeedsCheckpoint = false
        }
        apply(copy)
    }

    private func apply(_ new: ImageEdit) {
        guard new != edit else { return }
        let wantsSubject = new.removeBackground && !edit.removeBackground
        edit = new
        if wantsSubject { findSubject() }
        scheduleRender()
    }

    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }
    var canUndo: Bool { _ = history; return undoManager.canUndo }
    var canRedo: Bool { _ = history; return undoManager.canRedo }

    func revertAll() {
        change { $0 = ImageEdit() }
        selection = nil
    }

    var canSave: Bool { !edit.isEmpty }

    func save() {
        guard canSave else { return }
        onSave?(edit)
        onClose?()
    }

    func cancel() {
        onClose?()
    }

    // MARK: - Loading and drawing

    func load() {
        generation += 1
        loadTask?.cancel()
        subjectTask?.cancel()
        (source, mask, cache, preview, previewTab, loadError, renderError) = (nil, nil, nil, nil, nil, nil, nil)
        filterThumbnails = [:]
        subject = .idle
        selection = nil
        draft = nil
        let url = file.url
        let current = generation
        loadTask = Task {
            do {
                let loaded = try await Self.loadSource(url)
                guard current == generation else { return }
                source = loaded
                if edit.removeBackground { findSubject() }
                scheduleRender()
                let thumbnails = await Self.thumbnails(of: loaded)
                guard current == generation else { return }
                filterThumbnails = thumbnails.images
            } catch {
                guard current == generation else { return }
                loadError = error.localizedDescription
            }
        }
    }

    /// True while a new preview is being drawn (tests wait for it).
    var isRendering: Bool { renderTask != nil || loadTask.map { _ in source == nil && loadError == nil } == true }

    /// Draws again soon; several requests in a row draw once, with the latest edit.
    func scheduleRender() {
        renderAgain = true
        guard renderTask == nil else { return }
        renderTask = Task {
            while renderAgain {
                renderAgain = false
                await renderOnce()
            }
            renderTask = nil
        }
    }

    private func renderOnce() async {
        guard let source else { return }
        if showOriginal {
            preview = source.image
            previewTab = nil
            return
        }
        let shownTab = tab
        // The content (turned, cropped, adjusted) is kept between draws, so
        // drawing markup or moving a frame slider doesn't redo it.
        var contentEdit = edit
        contentEdit.markup = []
        contentEdit.format = nil
        contentEdit.frame = FrameStyle()
        if edit.removeBackground && edit.frame.background == .blur { contentEdit.frame.background = .blur }
        if shownTab == .crop {
            // The crop tab shows the whole turned picture, with the box on top.
            contentEdit.crop = nil
            contentEdit.aspect = nil
            contentEdit.outputSize = nil
            contentEdit.removeBackground = false
        }
        let usesMask = contentEdit.removeBackground ? mask : nil
        let key = CacheKey(edit: contentEdit, hasMask: usesMask != nil)
        let request = RenderRequest(
            source: source, mask: usesMask, contentEdit: contentEdit,
            cached: cache?.key == key ? cache?.content : nil,
            markupEdit: shownTab == .crop ? nil : edit,
            draft: shownTab == .markup ? draft : nil,
            watermark: shownTab == .crop ? nil : edit.watermark,
            frame: [.adjust, .background, .watermark].contains(shownTab) ? edit.frame : nil
        )
        let current = generation
        let result = await Self.render(request)
        guard current == generation else { return }
        if let content = result.content { cache = (key, content) }
        renderError = result.error
        if let image = result.image {
            preview = image
            previewTab = shownTab
        }
    }

    private struct RenderRequest: @unchecked Sendable {
        let source: StudioSource
        let mask: CGImage?
        let contentEdit: ImageEdit
        let cached: StudioContent?
        let markupEdit: ImageEdit?
        let draft: Annotation?
        let watermark: Watermark?
        let frame: FrameStyle?
    }

    private struct RenderResult: @unchecked Sendable {
        var image: CGImage?
        var content: StudioContent?
        var error: String?
    }

    private struct Thumbnails: @unchecked Sendable {
        var images: [PhotoFilter: CGImage] = [:]
    }

    private struct Subject: @unchecked Sendable {
        let mask: CGImage?
        var isPlainBackground = false
    }

    @concurrent
    private nonisolated static func loadSource(_ url: URL) async throws -> StudioSource {
        try StudioSource.load(url, maxPixelSize: previewSize)
    }

    @concurrent
    private nonisolated static func render(_ request: RenderRequest) async -> RenderResult {
        do {
            let content = try request.cached ?? StudioRenderer.content(request.source, mask: request.mask, edit: request.contentEdit)
            var image = content.image
            if let markupEdit = request.markupEdit {
                image = try StudioRenderer.drawMarkup(on: image, edit: markupEdit, source: request.source, extra: request.draft)
            }
            image = try StudioRenderer.drawWatermark(on: image, request.watermark)
            if let frame = request.frame {
                image = try StudioRenderer.framed(image, plain: content.plain, style: frame)
            }
            return RenderResult(image: image, content: content)
        } catch {
            return RenderResult(error: error.localizedDescription)
        }
    }

    /// A small square of the picture in each filter, for the filter buttons.
    @concurrent
    private nonisolated static func thumbnails(of source: StudioSource) async -> Thumbnails {
        let side = 96
        let image = source.image
        let crop = min(image.width, image.height)
        guard let square = image.cropping(to: CGRect(x: (image.width - crop) / 2, y: (image.height - crop) / 2, width: crop, height: crop)),
              let ctx = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return Thumbnails() }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = ctx.makeImage() else { return Thumbnails() }
        var result = Thumbnails()
        for filter in PhotoFilter.allCases {
            var edit = ImageEdit()
            edit.adjustments.filter = filter
            result.images[filter] = try? StudioRenderer.render(StudioSource(image: small), mask: nil, edit: edit)
        }
        return result
    }

    /// Vision's subject, else a plain background (as the saved file will do).
    private nonisolated static func findSubject(in source: StudioSource) async throws -> Subject {
        try await Blocking.run { _ in
            if let subject = try SubjectMask.make(for: source.image) { return Subject(mask: subject) }
            return Subject(mask: PlainBackground.mask(for: source.image), isPlainBackground: true)
        }
    }

    private func findSubject() {
        guard let source, mask == nil, subject != .finding else { return }
        subject = .finding
        let current = generation
        subjectTask = Task {
            do {
                let found = try await Self.findSubject(in: source)
                guard current == generation else { return }
                mask = found.mask
                subject = found.mask == nil ? .notFound : (found.isPlainBackground ? .plainBackground : .found)
                scheduleRender()
            } catch {
                guard current == generation else { return }
                subject = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Sizes

    /// The turned preview picture's size in pixels.
    var turnedSize: CGSize {
        source.map { StudioRenderer.turnedSize($0.size, edit) } ?? CGSize(width: 1, height: 1)
    }

    /// The crop box in pixels of the turned preview picture.
    var cropBox: CGRect {
        let size = turnedSize
        var rect = (edit.crop ?? .full).pixels(in: size)
        if let aspect = edit.aspect { rect = StudioRenderer.fitted(rect, aspect: aspect.value, in: size) }
        return rect
    }

    /// The crop as a share of the turned picture (where markup positions live).
    var cropShare: RelativeRect { RelativeRect(cropBox, in: turnedSize) }

    /// The result's size before the frame, at full size.
    var resultSize: PixelSize {
        source.map { StudioRenderer.contentSize(for: $0.fullSize, edit) } ?? PixelSize(width: 0, height: 0)
    }

    /// The crop's own size at full size (the result may be scaled from it).
    var cropPixelSize: PixelSize {
        var unscaled = edit
        unscaled.outputSize = nil
        return source.map { StudioRenderer.contentSize(for: $0.fullSize, unscaled) } ?? PixelSize(width: 0, height: 0)
    }

    var originalSize: PixelSize {
        source.map { PixelSize(width: Int($0.fullSize.width), height: Int($0.fullSize.height)) } ?? PixelSize(width: 0, height: 0)
    }

    /// The whole saved picture's size, frame included.
    var finalSize: PixelSize {
        source.map { StudioRenderer.finalSize(for: $0.fullSize, edit) } ?? PixelSize(width: 0, height: 0)
    }

    var format: OutputFormat? { edit.format }

    func setFormat(_ format: OutputFormat?) {
        change { $0.format = format }
    }

    /// What Automatic saves as for the picture shown.
    var automaticFormat: OutputFormat {
        var automatic = edit
        automatic.format = nil
        return automatic.outputFormat(for: file, hasAlpha: source?.hasAlpha ?? false)
    }

    // MARK: - Crop

    var aspect: AspectRatio? { edit.aspect }

    /// The original picture's shape, turned as shown.
    var originalAspect: AspectRatio {
        guard let source else { return .square }
        let size = StudioRenderer.turnedSize(source.fullSize, edit)
        return AspectRatio(size.width, size.height)
    }

    /// Picks a shape (nil: free). Presets follow the picture: 4:3 on a tall
    /// photo becomes 3:4. The box becomes the largest of that shape.
    func choose(aspect: AspectRatio?) {
        var shape = aspect
        if let preset = shape, preset != originalAspect, turnedSize.height > turnedSize.width, !preset.isPortrait {
            shape = preset.flipped
        }
        let size = turnedSize
        change { edit in
            edit.aspect = shape
            edit.outputSize = nil
            if let shape { edit.crop = RelativeRect(StudioRenderer.largest(aspect: shape.value, in: size), in: size) }
        }
    }

    /// Portrait ↔ landscape.
    func turnAspect() {
        guard let shape = edit.aspect, shape.width != shape.height else { return }
        let size = turnedSize
        let box = cropBox
        change { edit in
            edit.aspect = shape.flipped
            edit.crop = RelativeRect(StudioRenderer.fitted(box, aspect: shape.flipped.value, in: size), in: size)
            edit.outputSize = edit.outputSize.map { PixelSize(width: $0.height, height: $0.width) }
        }
    }

    func setResultWidth(_ width: Int) { setResultSize(width: width, height: nil) }
    func setResultHeight(_ height: Int) { setResultSize(width: nil, height: height) }

    /// Typing a width or height. With a fixed shape the other side follows;
    /// with a free crop, the crop takes the new shape.
    private func setResultSize(width: Int?, height: Int?) {
        let current = resultSize
        var newWidth = min(max(width ?? current.width, 1), 30_000)
        var newHeight = min(max(height ?? current.height, 1), 30_000)
        let size = turnedSize
        let box = cropBox
        change { edit in
            if let shape = edit.aspect {
                if width != nil {
                    newHeight = max(1, Int((Double(newWidth) / shape.value).rounded()))
                } else {
                    newWidth = max(1, Int((Double(newHeight) * shape.value).rounded()))
                }
            } else {
                let shape = AspectRatio(Double(newWidth), Double(newHeight))
                edit.aspect = shape
                edit.crop = RelativeRect(StudioRenderer.fitted(box, aspect: shape.value, in: size), in: size)
            }
            edit.outputSize = PixelSize(width: newWidth, height: newHeight)
        }
    }

    func useCropSize() {
        change { $0.outputSize = nil }
    }

    func resetCrop() {
        change { edit in
            edit.crop = nil
            edit.aspect = nil
            edit.outputSize = nil
        }
    }

    func rotate(clockwise: Bool) {
        change { $0.rotate(clockwise: clockwise) }
    }

    func flip(horizontally: Bool) {
        change { $0.flip(horizontally: horizontally) }
    }

    /// `point` is in pixels of the turned preview picture.
    func beginCrop(at point: CGPoint, tolerance: CGFloat) {
        isCropping = true
        gestureNeedsCheckpoint = true
        cropDrag = (CropMath.handle(at: point, in: cropBox, tolerance: tolerance), cropBox, point)
    }

    func moveCrop(to point: CGPoint) {
        guard let drag = cropDrag else { return }
        // A click outside the box shouldn't make a tiny new one.
        if drag.handle == .new && hypot(point.x - drag.start.x, point.y - drag.start.y) < 4 { return }
        let size = turnedSize
        let minSize = max(8, min(size.width, size.height) * 0.03)
        let rect = CropMath.dragged(
            drag.handle, rect: drag.rect, from: drag.start, to: point,
            aspect: edit.aspect?.value, bounds: size, minSize: minSize
        )
        update { $0.crop = RelativeRect(rect, in: size) }
    }

    func endCrop() {
        cropDrag = nil
        isCropping = false
        gestureNeedsCheckpoint = false
    }

    func cropHandle(at point: CGPoint, tolerance: CGFloat) -> CropHandle {
        CropMath.handle(at: point, in: cropBox, tolerance: tolerance)
    }

    // MARK: - Adjust and background

    /// Call when a slider starts moving (one undo step per move).
    func beginSliding() {
        gestureNeedsCheckpoint = true
    }

    func endSliding() {
        gestureNeedsCheckpoint = false
    }

    func setAdjustment(_ keyPath: WritableKeyPath<Adjustments, Double>, _ value: Double) {
        update { $0.adjustments[keyPath: keyPath] = value }
    }

    func setFrame(_ keyPath: WritableKeyPath<FrameStyle, Double>, _ value: Double) {
        update { $0.frame[keyPath: keyPath] = value }
    }

    func setFilter(_ filter: PhotoFilter) {
        change { $0.adjustments.filter = filter }
    }

    func setAutoEnhance(_ on: Bool) {
        change { $0.adjustments.auto = on }
    }

    func resetAdjustments() {
        change { $0.adjustments = Adjustments() }
    }

    func setBackdrop(_ backdrop: Backdrop) {
        change { edit in
            edit.frame.background = backdrop
            // A background is only seen around the picture: give it some room.
            if backdrop != .clear && edit.frame.padding == 0 && edit.frame.canvasAspect == nil { edit.frame.padding = 0.08 }
        }
    }

    func setCanvas(_ shape: AspectRatio?) {
        change { $0.frame.canvasAspect = shape }
    }

    func setRemoveBackground(_ on: Bool) {
        change { $0.removeBackground = on }
    }

    // MARK: - Straighten and watermark

    func setStraighten(_ degrees: Double) {
        update { $0.straighten = (degrees * 10).rounded() / 10 }
    }

    var watermark: Watermark? { edit.watermark }

    func setWatermarkShown(_ shown: Bool) {
        change { $0.watermark = shown ? (lastWatermark ?? Watermark()) : nil }
    }

    /// An undoable change to the watermark (sliders: `beginSliding` first, then `slideWatermark`).
    func changeWatermark(_ body: (inout Watermark) -> Void) {
        change { edit in
            var mark = edit.watermark ?? Watermark()
            body(&mark)
            edit.watermark = mark
        }
    }

    func slideWatermark(_ keyPath: WritableKeyPath<Watermark, Double>, _ value: Double) {
        update { $0.watermark?[keyPath: keyPath] = value }
    }

    /// Typing the text is one undo step.
    func setWatermarkText(_ text: String) {
        if textBeingTyped != Self.watermarkTyping {
            checkpoint()
            textBeingTyped = Self.watermarkTyping
        }
        apply({ var copy = edit; copy.watermark?.text = text; return copy }())
    }

    private static let watermarkTyping = UUID()

    func resetFrame() {
        change { edit in
            edit.frame = FrameStyle()
            edit.removeBackground = false
        }
    }

    // MARK: - Markup

    /// From a point in the shown (cropped) picture, 0...1, to a markup position.
    func markupPoint(fromShown point: CGPoint) -> RelativePoint {
        let crop = cropShare
        return RelativePoint(x: crop.x + point.x * crop.width, y: crop.y + point.y * crop.height)
    }

    /// From a markup position to a point in the shown picture, 0...1.
    func shownPoint(_ point: RelativePoint) -> CGPoint {
        let crop = cropShare
        return CGPoint(x: (point.x - crop.x) / max(crop.width, 0.0001), y: (point.y - crop.y) / max(crop.height, 0.0001))
    }

    var selected: Annotation? { edit.markup.first { $0.id == selection } }
    private var selectedIndex: Int? { edit.markup.firstIndex { $0.id == selection } }

    /// The area the selected annotation covers, as a share of the shown picture.
    var selectionFrame: CGRect? {
        guard let selected else { return nil }
        let bounds = selected.bounds(aspect: turnedSize.width / max(turnedSize.height, 1))
        let topLeft = shownPoint(RelativePoint(x: bounds.x, y: bounds.y))
        let bottomRight = shownPoint(RelativePoint(x: bounds.x + bounds.width, y: bounds.y + bounds.height))
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    /// The size a new annotation gets: the chosen S/M/L of what's shown.
    func size(for kind: Annotation.Kind) -> Double {
        let turned = turnedSize
        let box = cropBox
        return strokeSize.share(for: kind) * max(box.width, box.height) / max(turned.width, turned.height, 1)
    }

    var nextNumber: Int {
        (edit.markup.filter { $0.kind == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
    }

    func beginMarkup(at point: RelativePoint) {
        isMarking = true
        gestureNeedsCheckpoint = true
        moveDrag = nil
        if let tool {
            if tool.isPlaced {
                place(tool, at: point)
                return
            }
            selection = nil
            draft = Annotation(kind: tool, points: tool.isTwoPoint ? [point, point] : [point], color: color, size: size(for: tool))
            scheduleRender()
        } else if let hit = annotation(at: point) {
            selection = hit.id
            moveDrag = (hit.id, point, hit.points)
        } else {
            selection = nil
        }
    }

    func continueMarkup(to point: RelativePoint) {
        if var current = draft {
            if current.kind.isTwoPoint {
                current.points[1] = point
            } else if let last = current.points.last, hypot(point.x - last.x, point.y - last.y) > 0.0015 {
                current.points.append(point)
            }
            draft = current
            scheduleRender()
        } else if let drag = moveDrag, let index = edit.markup.firstIndex(where: { $0.id == drag.id }) {
            let dx = point.x - drag.start.x, dy = point.y - drag.start.y
            update { $0.markup[index].points = drag.points.map { $0.offset(dx: dx, dy: dy) } }
        }
    }

    func endMarkup() {
        isMarking = false
        gestureNeedsCheckpoint = false
        moveDrag = nil
        guard let finished = draft else { return }
        draft = nil
        let first = finished.points[0], last = finished.points[finished.points.count - 1]
        if finished.kind.isTwoPoint && hypot(first.x - last.x, first.y - last.y) < 0.004 {
            scheduleRender()  // a click, not a drag: nothing to add
        } else {
            change { $0.markup.append(finished) }
        }
    }

    private func place(_ kind: Annotation.Kind, at point: RelativePoint) {
        let text = kind == .number ? String(nextNumber) : (pendingText.isEmpty ? "Text" : pendingText)
        let placed = Annotation(kind: kind, points: [point], color: color, size: size(for: kind), text: text)
        change { $0.markup.append(placed) }
        selection = placed.id
        // After placing text, the next click selects (to move it); numbers keep counting.
        if kind == .text { tool = nil }
    }

    /// The topmost annotation under a point.
    func annotation(at point: RelativePoint) -> Annotation? {
        let aspect = turnedSize.width / max(turnedSize.height, 1)
        return edit.markup.last { annotation in
            let box = annotation.bounds(aspect: aspect)
            return point.x >= box.x && point.x <= box.x + box.width && point.y >= box.y && point.y <= box.y + box.height
        }
    }

    func setColor(_ newColor: MarkupColor) {
        color = newColor
        if let index = selectedIndex { change { $0.markup[index].color = newColor } }
    }

    func setStrokeSize(_ newSize: StrokeSize) {
        strokeSize = newSize
        if let index = selectedIndex {
            let kind = edit.markup[index].kind
            change { $0.markup[index].size = size(for: kind) }
        }
    }

    /// The selected text, or the text the Text tool will place.
    var text: String {
        if let selected, selected.kind == .text { return selected.text }
        return pendingText
    }

    func setText(_ newText: String) {
        guard let index = selectedIndex, edit.markup[index].kind == .text else {
            pendingText = newText
            return
        }
        // Typing is one undo step per annotation, not one per letter.
        let id = edit.markup[index].id
        if textBeingTyped != id {
            checkpoint()
            textBeingTyped = id
        }
        apply({ var copy = edit; copy.markup[index].text = newText; return copy }())
    }

    func deleteSelected() {
        guard let selection else { return }
        change { $0.markup.removeAll { $0.id == selection } }
        self.selection = nil
    }

    func clearMarkup() {
        change { $0.markup = [] }
        selection = nil
    }

    // MARK: - Blurring out faces and text

    private(set) var isFinding = false
    /// What finding faces or text came to.
    private(set) var findNote: String?

    /// Finds faces or text in the picture and blurs them out, as Blur Out
    /// markup (each can then be moved or deleted; Undo takes them all back).
    func blurOut(faces: Bool, text: Bool) {
        guard let source, !isFinding else { return }
        isFinding = true
        findNote = nil
        var turn = ImageEdit()
        turn.mirrored = edit.mirrored
        turn.quarterTurns = edit.quarterTurns
        turn.straighten = edit.straighten
        let request = FindRequest(source: source, turn: turn, faces: faces, text: text)
        Task {
            let found = await Self.find(request)
            isFinding = false
            guard let regions = found.regions else {
                findNote = found.error
                return
            }
            guard !regions.isEmpty else {
                findNote = faces ? "No faces were found." : "No text was found."
                return
            }
            change { $0.markup += PrivacyBlur.annotations(for: regions) }
            tool = nil
            let what = faces ? (regions.count == 1 ? "face" : "faces") : (regions.count == 1 ? "line of text" : "lines of text")
            findNote = "\(regions.count) \(what) blurred out."
        }
    }

    private struct FindRequest: @unchecked Sendable {
        let source: StudioSource
        let turn: ImageEdit
        let faces: Bool
        let text: Bool
    }

    private struct Found: Sendable {
        var regions: [RelativeRect]?
        var error: String?
    }

    /// On a thread of its own: Vision blocks its thread until it's done.
    private nonisolated static func find(_ request: FindRequest) async -> Found {
        do {
            return Found(regions: try await Blocking.run { _ in
                let turned = try StudioRenderer.render(request.source, mask: nil, edit: request.turn)
                return try PrivacyBlur.regions(in: turned, faces: request.faces, text: request.text)
            })
        } catch {
            return Found(error: error.localizedDescription)
        }
    }
}
