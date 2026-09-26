import Foundation
import VerdeClient

/// Swift boundary for the pure `vc_push_open` decrypt function (no host handle).
/// Decrypt and payload problems come back as a displayable generic
/// `PushNotification`; only a malformed request throws. Neither the request
/// (key records, envelope) nor the result is ever logged.
enum PushOpen {
    static func open(_ request: PushOpenRequest) throws -> PushNotification {
        let input = try JSONEncoder().encode(request)
        var output = vc_buf(ptr: nil, len: 0)
        defer { vc_buf_free(output) }
        let status = input.withUnsafeBytes { bytes in
            vc_push_open(bytes.bindMemory(to: UInt8.self).baseAddress, input.count, &output)
        }
        guard status == 0 else { throw CoreBridgeError.status(status) }
        guard let pointer = output.ptr else { throw CoreBridgeError.invalidOutput }
        return try JSONDecoder().decode(PushNotification.self, from: Data(bytes: pointer, count: output.len))
    }
}
