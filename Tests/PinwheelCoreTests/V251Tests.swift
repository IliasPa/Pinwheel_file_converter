import Foundation
import Testing
@testable import PinwheelCore

/// One name for every new file, with the Rename window's pattern words.
struct NewFileNameTests {
    private let desktop = URL(fileURLWithPath: "/Users/someone/Desktop", isDirectory: true)
    /// 23 November 2026, at noon.
    private let day = Date(timeIntervalSince1970: 1_795_435_200)

    private func name(_ pattern: String, usual: String = "New Word Document", ext: String = "docx") -> String {
        NewFileMaker.baseName(pattern: pattern, usual: usual, fileExtension: ext, folder: desktop, now: day)
    }

    @Test func noNameKeepsTheUsualOnes() {
        #expect(name("") == "New Word Document")
        #expect(name("   ") == "New Word Document")
        #expect(name("", usual: "Letterhead") == "Letterhead")
    }

    @Test func oneNameForEveryKind() {
        #expect(name("Untitled") == "Untitled")
        #expect(name("Untitled", usual: "New Excel Workbook", ext: "xlsx") == "Untitled")
        #expect(name("Untitled", usual: "Letterhead") == "Untitled", "your templates too")
        #expect(name("  Untitled  ") == "Untitled")
    }

    @Test func theRenameWordsWork() {
        #expect(name("{today} Notes") == "2026-11-23 Notes")
        #expect(name("{folder} {name}") == "Desktop New Word Document")
        #expect(name("{NAME} copy") == "New Word Document copy", "any case, as in Rename")
        #expect(NewFileMaker.nameTokens.map(\.token) == ["{name}", "{today}", "{folder}"])
    }

    @Test func aNameThatCantBeAFileNameIsMadeSafe() {
        #expect(name("Q1/Q2: plan") == "Q1-Q2- plan")
        #expect(name(".hidden") == "hidden", "a dot first would hide the file")
        #expect(name(". . notes") == "notes")
        #expect(name("{camera}") == "New Word Document", "nothing left: the usual name")
        #expect(name("...") == "New Word Document")
        let long = name(String(repeating: "a", count: 400))
        #expect(long.utf8.count + ".docx".utf8.count + " 99".utf8.count <= 255)
    }
}
