import Foundation

// TEMPORARY stand-in with the Gmail reader's public API (README, "Contract: Gmail reader"), so the rest of the app
// compiles while App/Mail is being written. Deleted when App/Mail/GmailIMAP.swift lands.

public struct MailMessage: Codable, Equatable {
    public let uid: UInt32
    public let date: Date?
    public let from: String
    public let subject: String
    public let text: String
}

public enum IMAPError: Error, LocalizedError {
    case connection(String), authenticationFailed, protocolError(String), timeout, mailboxNotFound
    public var errorDescription: String? { "Gmail reading is not built into this version yet" }
}

public final class GmailIMAPClient {
    public init(email: String, appPassword: String) {}

    public func fetch(query: String, sinceUID: UInt32?, uidValidity: UInt32?, limit: Int) async throws -> (messages: [MailMessage], uidValidity: UInt32, highestUID: UInt32) {
        throw IMAPError.connection("not built yet")
    }

    public func verifyLogin() async throws { throw IMAPError.connection("not built yet") }

    public static func defaultAlertQuery(since: Date) -> String { "" }
}
