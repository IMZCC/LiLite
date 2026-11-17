import Foundation

enum ServiceReceiptError {
  private static let maxHeader = 16 * 1024
  static func message(_ text: String) -> String {
    let scalars = text.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
    }
    return String(String(String.UnicodeScalarView(scalars)).prefix(600))
  }
  static func grpc(status: Int, headers: [String: String]) -> WireError {
    if let raw = headers["grpc-status-details-bin"], !raw.isEmpty, raw.utf8.count <= maxHeader {
      let padded = raw + String(repeating: "=", count: (4 - raw.utf8.count % 4) % 4)
      if let bytes = Data(base64Encoded: padded),
        let outer = try? PiliBilibiliRpc_Status(serializedBytes: bytes)
      {
        // As in GrpcReq.request, Bili's application code/message are inside Status.details[].value.
        let details = outer.details.prefix(16).compactMap { detail -> PiliBilibiliRpc_Status? in
          let name = detail.typeURL.split(separator: "/").last.map(String.init) ?? ""
          guard ["", "bilibili.rpc.Status", "google.rpc.Status"].contains(name),
            !detail.value.isEmpty,
            let value = try? PiliBilibiliRpc_Status(serializedBytes: detail.value),
            value.code != 0 || !value.message.isEmpty
          else { return nil }
          return value
        }
        let text = details.map(\.message).filter { !$0.isEmpty }.joined(separator: "\n")
        if let first = details.first {
          return .remote(
            first.code == 0 ? status : Int(first.code), message(text.isEmpty ? outer.message : text)
          )
        }
        if !outer.message.isEmpty { return .remote(status, message(outer.message)) }
      }
    }
    let raw = String((headers["grpc-message"] ?? "").prefix(maxHeader))
    return .remote(status, message(raw.removingPercentEncoding ?? raw))
  }
  static func json(_ response: GatewayReply) -> WireError? {
    struct Failure: Decodable { let code: Int?, message: String? }
    guard response.contentType.lowercased().split(separator: ";").first == "application/json",
      response.data.count <= maxHeader,
      let failure = try? JSONDecoder().decode(Failure.self, from: response.data),
      let text = failure.message, !text.isEmpty, failure.code != 0
    else { return nil }
    return .remote(failure.code ?? response.status, message(text))
  }
}
