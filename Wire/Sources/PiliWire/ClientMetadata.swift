import Foundation
import SwiftProtobuf

public enum ClientMetadata {
  /// The mobile token comes from an android_hd login (see MobilePassport), so the gRPC
  /// metadata must describe that same client. Claiming iphone/ios with this app's own build
  /// number made the IM gateway answer "鉴权失败，请联系账号组". Matches the original client.
  static let mobiApp = "android_hd", platform = "android", build: Int32 = 2_001_100,
    versionName = "2.0.1", channel = "master"
  public static func headers(device id: String, token: String?, build: Int32 = 0, version: String = "") throws -> [String: String] {
    var d = PiliBilibiliMetadataDevice_Device()
    d.appID = 5; d.buvid = id; d.mobiApp = mobiApp; d.platform = platform; d.device = platform
    d.channel = channel; d.brand = platform; d.model = platform; d.osver = "15"
    d.build = Self.build; d.versionName = versionName
    var m = PiliBilibiliMetadata_Metadata()
    m.buvid = id; m.mobiApp = mobiApp; m.platform = platform; m.device = platform; m.channel = channel
    m.build = Self.build
    if let token { m.accessKey = token }
    return ["buvid": id, "x-bili-device-bin": try d.serializedData().base64EncodedString(),
            "x-bili-metadata-bin": try m.serializedData().base64EncodedString()]
  }
}
