import Foundation
import Testing

@testable import MailCodeCore

struct GmailCredentialStoreTests {
    @Test func keychainRoundTripUpdateAndRemoval() throws {
        let store = KeychainGmailCredentialStore(service: "dev.zhijie.MailCodeFiller.tests.\(UUID())")
        defer {
            do { try store.remove() } catch {
                Issue.record(error, "Failed to remove the task-owned Keychain item")
            }
        }
        #expect(try store.load() == nil)
        let first = try GmailLogin.validated(email: " Person@Gmail.com ", appPassword: "abcd efgh ijkl mnop")
        try store.save(first)
        #expect(try store.load()?.email == "person@gmail.com")
        #expect(try store.load()?.appPassword == "abcdefghijklmnop")
        let second = GmailLogin(email: "second@gmail.com", appPassword: "ponmlkjihgfedcba")
        try store.save(second)
        #expect(try store.load()?.email == second.email)
        #expect(try store.load()?.appPassword == second.appPassword)
        try store.remove()
        #expect(try store.load() == nil)
        try store.remove()
    }
}
