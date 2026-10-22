import AppKit
import CoreImage
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.7.4: the small buttons under a copy, each pasting it changed a little.
@MainActor
struct ClipActionTests {
    private func add(_ store: ClipboardStore, _ types: [(UTType, Data)], app: String? = nil) throws -> ClipItem {
        try #require(store.add([types.map { (type: $0.0.identifier, data: $0.1) }], appID: app, appName: app))
    }

    /// What's on the clipboard, kept as the watcher would.
    private func keep(_ board: NSPasteboard, in store: ClipboardStore) throws -> ClipItem {
        let contents = try #require(ClipboardStore.read(board))
        return try #require(store.add(contents, appID: nil, appName: nil))
    }

    private func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }

    /// A picture of some text, black on white.
    private func textPicture(_ text: String) -> CGImage {
        let context = CGContext(data: nil, width: 1400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1400, height: 300))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(in: NSRect(x: 40, y: 40, width: 1320, height: 220), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private func qrPicture(_ message: String) throws -> CGImage {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(message.utf8)]))
        let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let padded = code.transformed(by: CGAffineTransform(translationX: 40, y: 40))
            .composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -40, dy: -40).offsetBy(dx: 40, dy: 40)))
        return try #require(CIContext().createCGImage(padded, from: padded.extent))
    }

    @Test func cleaningLinks() {
        let clean = ClipActions.cleanLinks
        #expect(clean("https://example.com/a?id=7&utm_source=news&utm_medium=email") == "https://example.com/a?id=7")
        #expect(clean("https://example.com/?fbclid=abc") == "https://example.com/")
        #expect(clean("Look: https://shop.example/x?gclid=1&color=red#top and https://youtu.be/abc?si=XYZ ok")
                == "Look: https://shop.example/x?color=red#top and https://youtu.be/abc ok")
        // "si" means something on other sites; the encoding stays as it was.
        #expect(clean("https://example.com/q?si=1&q=caf%C3%A9") == "https://example.com/q?si=1&q=caf%C3%A9")
        #expect(clean("No links here.") == "No links here.")
        #expect(clean("mailto:me@example.com?utm_source=x") == "mailto:me@example.com?utm_source=x")
    }

    @Test func changingText() {
        #expect(ClipActions.oneLine("First line\n  second   line \n\nthird") == "First line second line third")
        #expect(ClipActions.tidySpaces("  Too   many\tspaces  \n\n\n\nEnd ") == "Too many spaces\n\nEnd")
        #expect(ClipActions.sentenceCase("HELLO THERE. HOW ARE YOU? fine; thanks\nnew LINE") == "Hello there. How are you? Fine; thanks\nNew line")
        // In Greek, ";" ends a question.
        #expect(ClipActions.sentenceCase("ΤΙ ΚΑΝΕΙΣ; ΚΑΛΑ") == "Τι κανεις; Καλα")
    }

    @Test func whichButtonsShow() async throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let plain = try add(store, [(.utf8PlainText, Data("just words".utf8))])
        #expect(ClipActions.available(for: plain, store: store) == ClipAction.cases, "only capitals change it")
        let formatted = try add(store, [(.utf8PlainText, Data("Bold\n\nwords".utf8)), (.rtf, Data("{\\rtf1 \\b Bold}".utf8))])
        #expect(ClipActions.available(for: formatted, store: store) == [.plainText, .oneLine] + ClipAction.cases)
        let link = try add(store, [(.utf8PlainText, Data("https://example.com/?utm_campaign=x".utf8))])
        #expect(link.kind == .link && ClipActions.available(for: link, store: store) == [.cleanLinks])
        let messy = try add(store, [(.utf8PlainText, Data("a  b".utf8))])
        #expect(ClipActions.available(for: messy, store: store) == [.tidySpaces] + ClipAction.cases)
        let picture = try add(store, [(.png, png(textPicture("Hi")))])
        #expect(ClipActions.available(for: picture, store: store) == [.textInImage, .readCode])

        let board = NSPasteboard(name: NSPasteboard.Name("PinwheelTests-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([try scratch.image("photo.png"), scratch.url.appendingPathComponent("notes.txt")] as [NSURL])
        let files = try keep(board, in: store)
        #expect(ClipActions.available(for: files, store: store) == [.filePath, .fileName])
        board.clearContents()
        board.writeObjects([try scratch.image("one.png")] as [NSURL])
        let photo = try keep(board, in: store)
        #expect(ClipActions.available(for: photo, store: store) == [.textInImage, .readCode, .filePath, .fileName])
        let path = try await ClipActions.text(of: .filePath, for: photo, store: store, recognition: TextRecognition())
        #expect(path == scratch.url.appendingPathComponent("one.png").path)
    }

    @Test func readingPictures() async throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let words = try add(store, [(.png, png(textPicture("Pinwheel reads this")))])
        let read = try await ClipActions.text(of: .textInImage, for: words, store: store, recognition: TextRecognition())
        #expect(read?.contains("Pinwheel reads this") == true)
        let code = try add(store, [(.png, png(try qrPicture("Hello from a QR code")))])
        let decoded = try await ClipActions.text(of: .readCode, for: code, store: store, recognition: TextRecognition())
        #expect(decoded == "Hello from a QR code")
    }

    /// A button pastes the changed copy, keeps it in the history, and says
    /// so when there's nothing to paste.
    @Test func aButtonPastes() async throws {
        let scratch = try Scratch()
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.clipboardActions)
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        let controller = ClipboardController(settings: settings, store: ClipboardStore(folder: scratch.url), pasteboard: board)
        var pasted = 0
        controller.paste = { pasted += 1 }
        controller.mayPress = { true }
        let link = try add(controller.store, [(.utf8PlainText, Data("https://example.com/a?b=2&fbclid=xyz".utf8))], app: "Safari")
        controller.show()
        controller.model.isPinned = true  // so another test's window can't close it
        defer {
            controller.model.isPinned = false
            controller.hide()
        }

        controller.run(.cleanLinks, on: link)
        for _ in 0..<40 where pasted == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(pasted == 1 && board.string(forType: .string) == "https://example.com/a?b=2")
        #expect(controller.store.items.first?.preview == "https://example.com/a?b=2" && controller.store.items.first?.appName == "Safari")
        #expect(controller.store.items.count == 2, "kept, next to the original")

        // Closed before it was ready: only copied, not pasted into whatever is in front by then.
        let messy = try add(controller.store, [(.utf8PlainText, Data("a  b".utf8))])
        controller.model.isPinned = false
        controller.hide()
        controller.run(.tidySpaces, on: messy)
        for _ in 0..<40 where board.string(forType: .string) != "a b" { try await Task.sleep(for: .milliseconds(25)) }
        #expect(board.string(forType: .string) == "a b" && pasted == 1)

        let blank = try add(controller.store, [(.png, png(textPicture(" ")))])
        controller.run(.textInImage, on: blank)
        for _ in 0..<200 where controller.model.notice == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(controller.model.notice == ClipNotice(item: blank.id, text: "No text found"))
        #expect(pasted == 1 && controller.model.working == nil)

        settings.clipboardActions = false
        #expect(!SettingsStore(defaults: defaults).clipboardActions)
    }
}
