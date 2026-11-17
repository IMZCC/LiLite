import Foundation
import SwiftProtobuf

public enum ClientMetadata {
  public static func headers(device id: String, token: String?, build: Int32, version: String) throws -> [String: String] {
    var d = PiliBilibiliMetadataDevice_Device()
    d.buvid = id; d.mobiApp = "iphone"; d.platform = "ios"; d.device = "ios"; d.channel = "pilinative"
    d.build = build; d.versionName = version
    var m = PiliBilibiliMetadata_Metadata()
    m.buvid = id; m.mobiApp = d.mobiApp; m.platform = d.platform; m.device = d.device; m.channel = d.channel; m.build = build
    if let token { m.accessKey = token }
    return ["buvid": id, "x-bili-device-bin": try d.serializedData().base64EncodedString(),
            "x-bili-metadata-bin": try m.serializedData().base64EncodedString()]
  }
}
