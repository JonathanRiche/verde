import Foundation

/// CoreHost-actor owned. Only identified Git-summary HTTP completions are deferred;
/// response bodies and all mutation/lifecycle completions stay opaque.
struct CoreSummaryQueue {
    private var requests: [String: String] = [:]
    private var pending: [Event] = []
    var isEmpty: Bool { pending.isEmpty }

    mutating func track(_ effect: Effect) {
        switch effect {
        case .http_request(let request):
            guard let encoded = request.body_base64, let bytes = Data(base64Encoded: encoded),
                  let rpc = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  rpc["method"] as? String == "git.changes.summary" else { return }
            requests[request.effect_id] = request.generation
        case .http_cancel(let cancel):
            requests[cancel.request_id] = nil
            pending.removeAll { if case .http_response(let response) = $0 { return response.effect_id == cancel.request_id }; return false }
        default: break
        }
    }

    mutating func deferResponse(_ event: Event) -> Bool {
        guard case .http_response(let response) = event,
              requests[response.effect_id] == response.generation else { return false }
        requests[response.effect_id] = nil
        pending.append(event)
        return true
    }

    mutating func pop() -> Event? { pending.isEmpty ? nil : pending.removeFirst() }
    mutating func clear() { requests.removeAll(); pending.removeAll() }
}
