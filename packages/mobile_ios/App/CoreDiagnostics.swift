import Foundation
import OSLog

/// Explicit local opt-in. Never pass error descriptions, selectors, payloads or identifiers.
enum CoreDiagnostics {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "verde.connectionDiagnostics") }
    private static let logger = Logger(subsystem: "dev.verdeai.app", category: "connection")
    static func event(bytes: Int, nativeMilliseconds: Double, status: Int32?) {
        guard enabled else { return }
        logger.info("core bytes=\(bytes) native_ms=\(nativeMilliseconds) status=\(status ?? 0)")
    }
    static func failure(_ error: Error) {
        guard enabled else { return }
        let category: String
        switch error {
        case CoreBridgeError.status: category = "native_status"
        case is DecodingError: category = "decode"
        case is EncodingError: category = "encode"
        default: category = "bridge"
        }
        logger.info("core_failure category=\(category, privacy: .public)")
    }
    static func socket(open: Bool, ageMilliseconds: Int, code: UInt16?, clean: Bool) {
        guard enabled else { return }
        logger.info("socket open=\(open) age_ms=\(ageMilliseconds) code=\(code ?? 0) clean=\(clean)")
    }
}
