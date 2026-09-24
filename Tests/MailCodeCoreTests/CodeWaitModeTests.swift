import Foundation
import Testing

@testable import MailCodeCore

struct CodeWaitModeTests {
    @Test func windowExpiresAtItsOriginalDeadline() async throws {
        let controller = CodeWaitModeController(duration: .milliseconds(30))
        await controller.begin(.manual)
        let first = try #require(await controller.currentWindow())
        try await Task.sleep(for: .milliseconds(15))
        await controller.begin(.otpField)
        #expect(await controller.currentWindow() == first)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await controller.currentWindow() == nil)
    }

    @Test func repeatedBeginDoesNotExtendAndCancelPublishesNil() async throws {
        let controller = CodeWaitModeController(duration: .seconds(120))
        await controller.begin(.manual)
        let first = try #require(await controller.currentWindow())
        var iterator = controller.updates().makeAsyncIterator()
        let started = await iterator.next()
        #expect(started == first)
        await controller.begin(.otpField)
        #expect(await controller.currentWindow() == first)
        await controller.cancel()
        #expect(await controller.currentWindow() == nil)
        let stopped = await iterator.next()
        #expect(stopped == .some(nil))
    }
}
