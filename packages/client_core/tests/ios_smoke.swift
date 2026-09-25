import VerdeClient

// Compile and link only: device execution requires an app and signing (I-01).
print(String(cString: vc_version()))

let json = Array(#"{"api_version":1,"host_id":"swift","label":"Swift","https_url":null,"wss_url":null,"client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":1}"#.utf8)
var host: OpaquePointer?
let status = json.withUnsafeBufferPointer { vc_host_new($0.baseAddress, $0.count, &host) }
precondition(status == 0)
var snapshot = vc_buf(ptr: nil, len: 0)
let selector = Array("hosts".utf8)
precondition(selector.withUnsafeBufferPointer { vc_host_query(host, $0.baseAddress, $0.count, &snapshot) } == 0)
let stop = Array(#"{"api_version":1,"type":"shutdown","now_ms":0,"wall_time_ms":0}"#.utf8)
var batch = vc_buf(ptr: nil, len: 0)
precondition(stop.withUnsafeBufferPointer { vc_host_handle(host, $0.baseAddress, $0.count, &batch) } == 0)
vc_buf_free(batch)
vc_host_free(host)
vc_buf_free(snapshot)
