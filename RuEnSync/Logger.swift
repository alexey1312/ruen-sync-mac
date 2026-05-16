import Foundation
import os

enum Log {
    static let subsystem = "com.alexey1312.ruensync"

    static let layout = Logger(subsystem: subsystem, category: "layout")
    static let hid = Logger(subsystem: subsystem, category: "hid")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let app = Logger(subsystem: subsystem, category: "app")
}
