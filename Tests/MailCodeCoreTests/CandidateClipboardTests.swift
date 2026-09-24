import AppKit
import Foundation
import Testing

@testable import MailCodeCore

@Suite("Candidate clipboard privacy")
@MainActor
struct CandidateClipboardTests {
    private func candidate() -> Candidate {
        let now = Date()
        return Candidate(
            id: .init(
                message: MessageID(account: "a", mailbox: "INBOX", uidValidity: 1, uid: 1),
                index: 0),
            kind: .code("001234"), source: "example.test", subject: "登录",
            receivedAt: now, expiresAt: now.addingTimeInterval(300))
    }

    @Test func markersAndConditionalClear() throws {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = CandidateClipboard(pasteboard: board)
        let receipt = try clipboard.copy(candidate())
        #expect(board.string(forType: .string) == "001234")
        #expect(
            board.types?.contains(
                NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        #expect(
            board.types?.contains(
                NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != true)
        #expect(clipboard.autoClear.clearIfUnchanged(receipt))
        #expect(board.string(forType: .string) == nil)

        let timed = try clipboard.copy(candidate(), autoClearSeconds: 30)
        #expect(
            board.types?.contains(
                NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        board.clearContents()
        _ = board.setString("new content", forType: .string)
        #expect(!clipboard.autoClear.clearIfUnchanged(timed))
        #expect(board.string(forType: .string) == "new content")
        clipboard.autoClear.cancel()
    }
}
