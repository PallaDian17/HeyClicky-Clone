import OSLog

enum Log {
    static let subsystem = "com.ashish.heyclickyclone"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hud = Logger(subsystem: subsystem, category: "hud")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let auth = Logger(subsystem: subsystem, category: "auth")
}
