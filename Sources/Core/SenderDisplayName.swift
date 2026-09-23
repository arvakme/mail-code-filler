import Foundation

public enum SenderDisplayName {
    public static func fromHeader(_ header: String) -> String {
        let header = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = header.lastIndex(of: "<"),
            let close = header[open...].firstIndex(of: ">"), open < close
        else { return header }

        let name = header[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let address = header[header.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return address }

        guard name.count >= 2, name.first == "\"", name.last == "\"" else {
            return name
        }
        return String(name.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
