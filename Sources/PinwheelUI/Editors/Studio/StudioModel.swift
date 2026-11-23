import AppKit
import Observation
import PinwheelCore
import UniformTypeIdentifiers

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

    /// The Size slider: 0...1, with Small, Medium and Large as the notches at
    /// a quarter, a half and three quarters. Between them is any size; past
    /// them are smaller and bigger ones.
    enum SizeScale {
        static let notches = [0.25, 0.5, 0.75]

        /// Line widths and text sizes of Small, Medium and Large, as a share of the picture's longer side.
        static func steps(for kind: Annotation.Kind) -> (Double, Double, Double) {
            switch kind {
            case .text: (0.035, 0.05, 0.075)
            case .number: (0.04, 0.055, 0.08)
            case .highlighter: (0.02, 0.03, 0.045)
            case .checkmark, .cross: (0.004, 0.007, 0.012)
            default: (0.004, 0.007, 0.012)
            }
        }

        private static func stops(for kind: Annotation.Kind) -> [(level: Double, share: Double)] {
            let (small, medium, large) = steps(for: kind)
            return [(0, small * 0.4), (0.25, small), (0.5, medium), (0.75, large), (1, large * 1.8)]
        }

        static func share(level: Double, for kind: Annotation.Kind) -> Double {
            let stops = stops(for: kind)
            let level = min(max(level, 0), 1)
            for index in 1..<stops.count where level <= stops[index].level {
                let (a, b) = (stops[index - 1], stops[index])
                return a.share + (b.share - a.share) * (level - a.level) / (b.level - a.level)
            }
            return stops[stops.count - 1].share
        }

        static func level(share: Double, for kind: Annotation.Kind) -> Double {
            let stops = stops(for: kind)
            for index in 1..<stops.count where share <= stops[index].share {
                let (a, b) = (stops[index - 1], stops[index])
                return a.level + (b.level - a.level) * (share - a.share) / (b.share - a.share)
            }
            return 1
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
    var tool: Annotation.Kind? = .arrow {
        didSet {
            // Pixel Zoom is a tool of its own: choosing another one ends it.
            if tool != oldValue { pixelZoom = false }
            if tool == .redact || tool == .blur, let tool { blurStyle = tool }
        }
    }
    /// The Blur tool's style: in blocks (`.redact`) or smooth (`.blur`). New
    /// blurs, drawn or found by themselves, get it.
    private(set) var blurStyle: Annotation.Kind = .redact

    /// Whether the Blur tool is chosen (in either style).
    var isBlurTool: Bool { tool == .redact || tool == .blur }

    /// Whether the Blur tool's settings show: it's chosen, or a blur is selected.
    var showsBlurSettings: Bool {
        isBlurTool || selected?.kind == .redact || selected?.kind == .blur
    }

    /// The tools panel's Blur button: the style used last.
    func chooseBlurTool() {
        tool = blurStyle
        selection = nil
    }

    /// Blocks or smooth: for the next blurs, and the selected blur changes too.
    func setBlurStyle(_ style: Annotation.Kind) {
        guard style == .redact || style == .blur else { return }
        blurStyle = style
        if isBlurTool { tool = style }
        if let index = selectedIndex, edit.markup[index].kind == .redact || edit.markup[index].kind == .blur,
           edit.markup[index].kind != style {
            change { $0.markup[index].kind = style }
        }
    }

    /// The Pixel Zoom tool: a magnifier follows the pointer; a click copies
    /// the color code of the pixel under it.
    var isPixelZoomTool: Bool { tool == nil && pixelZoom }

    func choosePixelZoomTool() {
        tool = nil
        selection = nil
        pixelZoom = true
    }

    private(set) var color = MarkupColor.red
    /// The Size slider's place for lines, shapes and text.
    private(set) var sizeLevel = 0.5
    /// The slider's place for the tools that blur or dim.
    private(set) var strengthLevel = 0.5
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
        zoomToFit()
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

    // MARK: - Zoom

    /// How far the picture is enlarged: 1 fits it in the window.
    private(set) var zoom: CGFloat = 1
    /// How far the picture's middle is from the window's middle, in points.
    private(set) var pan: CGSize = .zero
    /// The picture area's size (the canvas reports it), for zooming around a point.
    var canvasSize: CGSize = .zero
    static let zoomRange: ClosedRange<CGFloat> = 1...8

    var isZoomed: Bool { zoom > 1.001 }
    var zoomText: String { "\(Int((zoom * 100).rounded()))%" }

    /// Where the picture is drawn inside an area of `size` points.
    func imageRect(in size: CGSize) -> CGRect {
        guard let image = preview else { return .zero }
        let margin = StudioCanvas.margin(for: tab)
        let area = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let base = StudioCanvas.fit(CGSize(width: image.width, height: image.height), in: area)
        let (width, height) = (base.width * zoom, base.height * zoom)
        let moved = Self.clamped(pan, picture: CGSize(width: width, height: height), in: area.size)
        return CGRect(x: area.midX + moved.width - width / 2, y: area.midY + moved.height - height / 2, width: width, height: height)
    }

    /// A shift that leaves no gap between the picture and the window's edges
    /// (a picture smaller than the window stays in the middle).
    static func clamped(_ pan: CGSize, picture: CGSize, in area: CGSize) -> CGSize {
        let limitX = max(0, (picture.width - area.width) / 2)
        let limitY = max(0, (picture.height - area.height) / 2)
        return CGSize(width: min(max(pan.width, -limitX), limitX), height: min(max(pan.height, -limitY), limitY))
    }

    /// Zooms to `level` keeping the spot under `point` (view coordinates;
    /// nil: the middle) where it is.
    func setZoom(_ level: CGFloat, around point: CGPoint? = nil) {
        let new = min(max(level, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard new != zoom else { return }
        let size = canvasSize
        let old = imageRect(in: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let spot = point ?? center
        let ratio = new / zoom
        // The picture's middle moves away from (or toward) the spot.
        let middle = CGPoint(x: old.midX, y: old.midY)
        let moved = CGPoint(x: spot.x + (middle.x - spot.x) * ratio, y: spot.y + (middle.y - spot.y) * ratio)
        zoom = new
        pan = CGSize(width: moved.x - center.x, height: moved.y - center.y)
        pan = Self.pan(of: imageRect(in: size), in: size)
        if !isZoomed { pan = .zero }
    }

    /// How far a drawn picture's middle is from the middle of its area.
    private static func pan(of rect: CGRect, in size: CGSize) -> CGSize {
        CGSize(width: rect.midX - size.width / 2, height: rect.midY - size.height / 2)
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }
    func zoomToFit() {
        zoom = 1
        pan = .zero
    }

    /// Actual pixels: one picture pixel per screen pixel (as far as the preview allows).
    func zoomToActualSize(scale: CGFloat) {
        guard let image = preview, canvasSize.width > 0 else { return }
        let fit = StudioCanvas.fit(CGSize(width: image.width, height: image.height), in: CGRect(origin: .zero, size: canvasSize)).width
        guard fit > 0 else { return }
        setZoom(CGFloat(image.width) / scale / fit)
    }

    /// Scrolls the picture by `delta` points (when it's bigger than the window).
    func panBy(_ delta: CGSize) {
        guard isZoomed else { return }
        let moved = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        pan = moved
        pan = Self.pan(of: imageRect(in: canvasSize), in: canvasSize)
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

    /// Where the ruler began (before it was snapped to an edge).
    private var measureStart: RelativePoint?

    /// The picture as it's shown, for finding edges: it follows the crop, so
    /// the ruler stops where you see an edge.
    private var edges: EdgeMap? {
        guard let image = cache?.content.image else { return nil }
        if let cachedEdges, cachedEdges.image === image { return cachedEdges.map }
        let map = EdgeMap(image)
        cachedEdges = map.map { (image, $0) }
        return map
    }

    @ObservationIgnored private var cachedEdges: (image: CGImage, map: EdgeMap)?

    /// A straight ruler from `start` toward `end`, along the longer way, both
    /// ends pulled to the nearest edge.
    private func snappedRuler(from start: RelativePoint, to end: RelativePoint) -> [RelativePoint] {
        guard let map = edges else { return [start, end] }
        let width = Double(map.width), height = Double(map.height)
        let a = shownPoint(start), b = shownPoint(end)
        let (ax, ay, bx, by) = (a.x * width, a.y * height, b.x * width, b.y * height)
        let horizontal = abs(bx - ax) >= abs(by - ay)
        let radius = 8
        func shown(_ x: Double, _ y: Double) -> RelativePoint {
            markupPoint(fromShown: CGPoint(x: x / width, y: y / height))
        }
        if horizontal {
            let line = Int(ay.rounded())
            let from = map.snap(Int(ax.rounded()), line: line, horizontal: true, radius: radius)
            let to = map.snap(Int(bx.rounded()), line: line, horizontal: true, radius: radius)
            return [shown(Double(from), ay), shown(Double(to), ay)]
        }
        let line = Int(ax.rounded())
        let from = map.snap(Int(ay.rounded()), line: line, horizontal: false, radius: radius)
        let to = map.snap(Int(by.rounded()), line: line, horizontal: false, radius: radius)
        return [shown(ax, Double(from)), shown(ax, Double(to))]
    }

    /// The ruler across the space around a point, edge to edge.
    private func spanRuler(at point: RelativePoint, vertical: Bool) -> [RelativePoint]? {
        guard let map = edges else { return nil }
        let width = Double(map.width), height = Double(map.height)
        let spot = shownPoint(point)
        let (x, y) = (Int((spot.x * width).rounded(.down)), Int((spot.y * height).rounded(.down)))
        let span = map.span(x: x, y: y, horizontal: !vertical)
        guard span.end - span.start >= 2 else { return nil }
        func shown(_ px: Double, _ py: Double) -> RelativePoint { markupPoint(fromShown: CGPoint(x: px / width, y: py / height)) }
        return vertical
            ? [shown(spot.x * width, Double(span.start)), shown(spot.x * width, Double(span.end))]
            : [shown(Double(span.start), spot.y * height), shown(Double(span.end), spot.y * height)]
    }

    // Pixel zoom

    /// Where the pointer is over the picture, 0...1 of what's shown (nil: off it).
    var hover: CGPoint?
    /// Show the pixel zoom: the Pixel Zoom tool (the Measure tool shows it anyway).
    var pixelZoom = false
    var showsZoom: Bool { (pixelZoom || tool == .measure) && hover != nil && tab == .markup }
    /// The zoom takes this many pixels across.
    static let zoomPixels = 15

    /// The pixels around the pointer, and the center pixel's color and place.
    var zoomPatch: (image: CGImage, x: Int, y: Int, hex: String)? {
        guard let hover, let image = cache?.content.image else { return nil }
        let x = min(max(Int((hover.x * Double(image.width)).rounded(.down)), 0), image.width - 1)
        let y = min(max(Int((hover.y * Double(image.height)).rounded(.down)), 0), image.height - 1)
        let half = Self.zoomPixels / 2
        let left = min(max(x - half, 0), max(image.width - Self.zoomPixels, 0))
        let top = min(max(y - half, 0), max(image.height - Self.zoomPixels, 0))
        let rect = CGRect(x: left, y: top, width: min(Self.zoomPixels, image.width), height: min(Self.zoomPixels, image.height))
        guard let patch = image.cropping(to: rect) else { return nil }
        return (patch, x - left, y - top, Self.hex(ofPixelAt: x, y, in: image))
    }

    private static func hex(ofPixelAt x: Int, _ y: Int, in image: CGImage) -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let ctx = CGContext(
                  data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return "" }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
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
        return SizeScale.share(level: sizeLevel, for: kind) * max(box.width, box.height) / max(turned.width, turned.height, 1)
    }

    var nextNumber: Int {
        (edit.markup.filter { $0.kind == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
    }

    func beginMarkup(at point: RelativePoint) {
        isMarking = true
        gestureNeedsCheckpoint = true
        moveDrag = nil
        if isPixelZoomTool {
            copyColor(at: point)
            return
        }
        // The Blur tool picks up a blur that's there (to move it, or delete it
        // with Backspace), so blurs found by themselves can go one by one.
        if isBlurTool, let hit = annotation(at: point), hit.kind == .redact || hit.kind == .blur {
            selection = hit.id
            moveDrag = (hit.id, point, hit.points)
            return
        }
        if let tool {
            if tool.isPlaced {
                place(tool, at: point)
                return
            }
            selection = nil
            measureStart = point
            draft = Annotation(
                kind: tool, points: tool.isTwoPoint ? [point, point] : [point], color: color, size: size(for: tool),
                strength: strengthLevel
            )
            if tool == .measure { draft?.points = snappedRuler(from: point, to: point) }
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
            if current.kind == .measure, let start = measureStart {
                current.points = snappedRuler(from: start, to: point)
            } else if current.kind.isTwoPoint {
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
        if finished.kind == .measure, hypot(first.x - last.x, first.y - last.y) < 0.004, let click = measureStart,
           let span = spanRuler(at: click, vertical: NSEvent.modifierFlags.contains(.option)) {
            var ruler = finished
            ruler.points = span
            change { $0.markup.append(ruler) }  // a click measures the space between the edges around it
        } else if finished.kind.isTwoPoint && hypot(first.x - last.x, first.y - last.y) < 0.004 {
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

    /// The screen's own color picker: any pixel on any screen becomes the
    /// markup color, and its code ("#4338CA") is copied.
    func pickColorFromScreen() {
        let sampler = NSColorSampler()
        sampler.show { [weak self] picked in
            guard let picked else { return }
            MainActor.assumeIsolated {
                guard let self, let rgb = picked.usingColorSpace(.sRGB) else { return }
                self.setColor(MarkupColor(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)))
                let code = MarkupColor.hexCode(rgb)
                self.pasteboard.clearContents()
                self.pasteboard.setString(code, forType: .string)
                self.colorNote = "Picked \(code) (copied)."
            }
        }
    }

    /// The Pixel Zoom tool's click: the code of the pixel under the pointer is copied.
    private func copyColor(at point: RelativePoint) {
        let shown = shownPoint(point)
        let saved = hover
        hover = shown
        defer { hover = saved }
        guard let code = zoomPatch?.hex, !code.isEmpty else { return }
        self.pasteboard.clearContents()
        self.pasteboard.setString(code, forType: .string)
        colorNote = "Copied \(code)."
    }

    /// Where copies go (tests use one of their own).
    @ObservationIgnored var pasteboard = NSPasteboard.general

    /// What the color picker or Pixel Zoom did last.
    private(set) var colorNote: String?

    /// The last contrast check: the text color, the background, and how readable it is.
    private(set) var contrast: (text: MarkupColor, background: MarkupColor, check: ContrastCheck)?
    /// "Now click the background…" between the two clicks.
    private(set) var contrastStep: String?

    /// Two clicks on the screen: the text, then what's behind it. The result
    /// is the WCAG contrast ratio (the one accessibility checks use).
    func checkContrast() {
        contrast = nil
        contrastStep = "Click the text color…"
        sample { [weak self] text in
            guard let self else { return }
            guard let text else { self.contrastStep = nil; return }
            self.contrastStep = "Now click the background behind it…"
            self.sample { [weak self] background in
                guard let self else { return }
                self.contrastStep = nil
                guard let background else { return }
                self.contrast = (text, background, ContrastCheck(text, on: background))
            }
        }
    }

    /// One pick with the system's color picker.
    private func sample(_ done: @escaping @MainActor (MarkupColor?) -> Void) {
        let sampler = NSColorSampler()
        sampler.show { picked in
            MainActor.assumeIsolated {
                guard let rgb = picked?.usingColorSpace(.sRGB) else { return done(nil) }
                done(MarkupColor(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)))
            }
        }
    }

    /// Says how the last "copy" went.
    private(set) var copyNote: String?
    private(set) var isCopying = false

    /// Puts the edited picture, as it would be saved, on the clipboard.
    func copyResult() {
        guard !isCopying else { return }
        isCopying = true
        copyNote = nil
        let (url, current) = (file.url, edit)
        Task {
            defer { isCopying = false }
            do {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-copy-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: temp) }
                try await Blocking.run { _ in
                    try StudioExporter.export(url, edit: current, format: .png, destination: temp, options: ConversionOptions())
                }
                guard let picture = NSImage(contentsOf: temp) else { throw CocoaError(.fileReadCorruptFile) }
                self.pasteboard.clearContents()
                self.pasteboard.writeObjects([picture])
                copyNote = "Copied to the clipboard."
            } catch {
                copyNote = "Couldn't copy: \(error.localizedDescription)"
            }
        }
    }

    /// The kind the Size slider is for: the selected one's, else the tool's.
    var sliderKind: Annotation.Kind? {
        let kind = selected?.kind ?? tool
        return kind == .erase ? nil : kind  // an erase (made before 2.3.2) has nothing to size
    }

    /// True when the slider is a strength (blur, pixel blocks, dimming), not a size.
    var sliderIsStrength: Bool { sliderKind?.usesStrength ?? false }

    /// Where the slider's thumb is.
    var sliderValue: Double {
        if let selected {
            if selected.kind.usesStrength { return selected.strength }
            let box = cropBox, turned = turnedSize
            let factor = max(box.width, box.height) / max(turned.width, turned.height, 1)
            return SizeScale.level(share: selected.size / max(factor, 0.000_001), for: selected.kind)
        }
        return sliderIsStrength ? strengthLevel : sizeLevel
    }

    /// Moves the slider (inside a drag: `beginSliding` came first).
    func setSliderValue(_ value: Double) {
        guard let kind = sliderKind else { return }
        if kind.usesStrength { strengthLevel = value } else { sizeLevel = value }
        guard let index = selectedIndex else { return }
        if kind.usesStrength {
            update { $0.markup[index].strength = value }
        } else {
            let newSize = size(for: kind)
            update { $0.markup[index].size = newSize }
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

    /// Backspace or Delete: deletes the selected mark.
    func deleteKey() { deleteSelected() }

    /// Whether Backspace has something to do (and isn't a letter being typed).
    var canDeleteByKey: Bool {
        if tab != .markup { return false }
        if let selected { return selected.kind != .text || tool != .text }
        return false
    }

    func deleteSelected() {
        guard let selection else { return }
        change { $0.markup.removeAll { $0.id == selection } }
        self.selection = nil
    }

    // MARK: - Blurring out faces and text by themselves

    private(set) var isFinding = false
    /// What finding faces or text came to.
    private(set) var findNote: String?

    /// Tests put marks in without a picture being found.
    func beginMarkupForTesting(_ marks: [Annotation]) {
        change { $0.markup = marks }
    }

    /// Whether blurring this kind out by itself is on: its marks are in the picture.
    func isAutoBlurOn(_ kind: PrivacyBlur.Kind) -> Bool {
        edit.markup.contains { $0.auto == kind.rawValue }
    }

    /// The Blur tool's switches: faces, e-mail addresses, numbers or all
    /// text. On: finds them and blurs each out in the chosen style, as marks
    /// that can be moved or deleted one by one. Off: takes all of that kind
    /// away (Undo brings them back).
    func setAutoBlur(_ kind: PrivacyBlur.Kind, on: Bool) {
        if !on {
            change { $0.markup.removeAll { $0.auto == kind.rawValue } }
            selection = nil
            findNote = nil
            return
        }
        guard let source, !isFinding, !isAutoBlurOn(kind) else { return }
        isFinding = true
        findNote = nil
        var turn = ImageEdit()
        turn.mirrored = edit.mirrored
        turn.quarterTurns = edit.quarterTurns
        turn.straighten = edit.straighten
        let request = FindRequest(source: source, turn: turn, kinds: [kind])
        let style = blurStyle
        Task {
            let result = await Self.find(request)
            isFinding = false
            guard let items = result.items else {
                findNote = result.error
                return
            }
            guard !items.isEmpty else {
                findNote = "No \(kind.noun) found."
                return
            }
            change { $0.markup += PrivacyBlur.annotations(for: items, style: style) }
            findNote = "\(items.count) \(items.count == 1 ? kind.singular : kind.noun) blurred out. Click one and press Backspace to keep it visible."
        }
    }

    private struct FindRequest: @unchecked Sendable {
        let source: StudioSource
        let turn: ImageEdit
        let kinds: Set<PrivacyBlur.Kind>
    }

    private struct Found: Sendable {
        var items: [PrivacyBlur.Found]?
        var error: String?
    }

    /// The picture as it's turned, at most 2048 pixels across (the regions
    /// are shares of it, so that's plenty), goes to Pinwheel's reader: Vision
    /// runs there and its memory goes back to macOS a minute later.
    private nonisolated static func find(_ request: FindRequest) async -> Found {
        do {
            let file = try await Blocking.run { _ in
                let turned = try StudioRenderer.render(request.source, mask: nil, edit: request.turn)
                return try writeForReading(turned)
            }
            defer { try? FileManager.default.removeItem(at: file) }
            return Found(items: try await PictureReader.shared.found(in: file, kinds: request.kinds))
        } catch {
            return Found(error: error.localizedDescription)
        }
    }

    private nonisolated static func writeForReading(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-read-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationImageMaxPixelSize: 2048, kCGImageDestinationLossyCompressionQuality: 0.92,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.cannotWrite(url.lastPathComponent) }
        return url
    }
}
