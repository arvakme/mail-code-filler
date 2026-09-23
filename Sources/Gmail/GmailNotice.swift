enum GmailNotice {
    static let undecodable = "有一封邮件无法解码，已跳过。"
    static let partialDecode = "有一封邮件的部分正文无法解码，只会识别可读的正文。"
    static let noText = "有一封邮件没有可读取的文本正文，已跳过。"
    static let incomplete = "最近邮件超过读取上限，保留窗口内可能还有未读取的邮件。"
    static let unusableDate = "有一封邮件缺少可用的服务器接收时间，已跳过。"
    static let futureDate = "邮件接收时间比本机时间超前，稍后会重查；请检查 Mac 的日期与时间。"
    static let oversized = "有一封邮件正文超过大小限制，已跳过。"
    static let missingValidity = "服务器没有提供 UIDVALIDITY，这次收到的邮件可能无法和以后的邮件区分。"
}
