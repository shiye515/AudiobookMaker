import OSLog

nonisolated enum AppLog {
    static let subsystem = "top.shifenniu.AudiobookMaker"
    static let importing = Logger(subsystem: subsystem, category: "import")
    static let conversion = Logger(subsystem: subsystem, category: "conversion")
    static let packaging = Logger(subsystem: subsystem, category: "packaging")
    static let exporting = Logger(subsystem: subsystem, category: "export")
    static let recovery = Logger(subsystem: subsystem, category: "recovery")
    static let application = Logger(subsystem: subsystem, category: "application")

    static let importSignposter = OSSignposter(subsystem: subsystem, category: "import")
    static let conversionSignposter = OSSignposter(subsystem: subsystem, category: "conversion")
    static let exportSignposter = OSSignposter(subsystem: subsystem, category: "export")
}
