import PiliWireZlib
import Foundation

#if canImport(Compression)
  import Compression
#elseif canImport(CBrotli)
  import CBrotli
#endif

public enum RoomFrame: Equatable, Sendable {
  case authenticated
  case popularity(UInt32)
  case event(Data)
}
public enum LivePackets {
  public static func encode(_ op: UInt32, data: Data, sequence: UInt32 = 1) throws -> Data {
    guard data.count <= 4 * 1024 * 1024 else { throw WireError.invalid("直播数据过大") }
    var bytes = Data()
    func put<T: FixedWidthInteger>(_ n: T) {
      withUnsafeBytes(of: n.bigEndian) { bytes.append(contentsOf: $0) }
    }
    put(UInt32(data.count + 16))
    put(UInt16(16))
    put(UInt16(1))
    put(op)
    put(sequence)
    bytes.append(data)
    return bytes
  }
  public static func decode(_ packet: Data) throws -> [RoomFrame] {
    var budget = 8 * 1024 * 1024
    var frames: [RoomFrame] = []
    var count = 0
    func parse(_ data: Data, depth: Int) throws {
      guard depth <= 3, data.count <= 8 * 1024 * 1024 else { throw WireError.invalid("直播帧超出限制") }
      let bytes = [UInt8](data)
      var pos = 0
      func n(_ at: Int, _ len: Int) -> Int { bytes[at..<at + len].reduce(0) { $0 << 8 | Int($1) } }
      while pos < bytes.count {
        guard bytes.count - pos >= 16, count < 32000 else { throw WireError.invalid("直播帧不完整") }
        count += 1
        let len = n(pos, 4)
        let header = n(pos + 4, 2)
        let version = n(pos + 6, 2)
        let op = n(pos + 8, 4)
        guard header >= 16, len >= header, len <= bytes.count - pos else {
          throw WireError.invalid("直播帧长度无效")
        }
        let range = (pos + header)..<(pos + len)
        pos += len
        switch op {
        case 3:
          guard range.count >= 4 else { throw WireError.invalid("直播人气信息不完整") }
          frames.append(.popularity(UInt32(n(range.lowerBound, 4))))
        case 8:
          struct Auth: Decodable { let code: Int }
          let auth = try JSONDecoder().decode(Auth.self, from: Data(bytes[range]))
          guard auth.code == 0 else { throw WireError.remote(auth.code, "直播弹幕连接未获授权") }
          frames.append(.authenticated)
        case 5:
          let payload = Data(bytes[range])
          if version == 2 || version == 3 {
            guard !payload.isEmpty, budget >= 16 else { throw WireError.invalid("直播弹幕数据过大") }
            let inflated = try unpack(payload, brotli: version == 3, limit: budget)
            budget -= inflated.count
            try parse(inflated, depth: depth + 1)
          } else if version == 0 || version == 1 {
            frames.append(.event(payload))
          } else {
            throw WireError.invalid("直播弹幕格式不受支持")
          }
        default: continue
        }
      }
    }
    try parse(packet, depth: 0)
    return frames
  }
  private static func unpack(_ input: Data, brotli: Bool, limit: Int) throws -> Data {
    guard limit > 0, !input.isEmpty else { throw WireError.invalid("直播压缩帧为空") }
    #if canImport(Compression)
      // Apple's one-shot decoder answers 0, not the buffer size, when a Brotli frame doesn't fit,
      // so it can't grow its own output; the streaming decoder can.
      if brotli { return try brotliStream(input, limit: limit) }
    #endif
    let maxSize = limit + 1
    var size = min(maxSize, max(2048, input.count * 2))
    return try input.withUnsafeBytes { source in
      let src = source.bindMemory(to: UInt8.self).baseAddress!
      while size <= maxSize {
        var output = [UInt8](repeating: 0, count: size)
        var written = size
        var short = false
        if brotli {
          #if canImport(CBrotli) && !canImport(Compression)
            // The streaming API distinguishes truncated input from an output buffer that filled up.
            guard let state = BrotliDecoderCreateInstance(nil, nil, nil) else {
              throw WireError.invalid("无法解压直播帧")
            }
            var left = input.count
            var room = size
            var sourcePtr: UnsafePointer<UInt8>? = src
            let result = output.withUnsafeMutableBufferPointer { dst in
              var target = dst.baseAddress
              return BrotliDecoderDecompressStream(state, &left, &sourcePtr, &room, &target, nil)
            }
            BrotliDecoderDestroyInstance(state)
            written = size - room
            short = result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT
            guard short || (result == BROTLI_DECODER_RESULT_SUCCESS && left == 0) else {
              throw WireError.invalid("Brotli 直播帧无效")
            }
          #else
            throw WireError.invalid("当前设备无法解压 Brotli 直播帧")
          #endif
        } else {
          var length = uLongf(size)
          var sourceLength = uLong(input.count)
          let rc = uncompress2(&output, &length, src, &sourceLength)
          short = rc == Z_BUF_ERROR
          written = Int(length)
          guard short || (rc == Z_OK && sourceLength == input.count) else {
            throw WireError.invalid("zlib 直播帧无效")
          }
        }
        if !short {
          guard written <= limit, written > 0 else { throw WireError.invalid("直播弹幕数据过大") }
          return Data(output.prefix(written))
        }
        guard size < maxSize else { break }
        size = min(size * 2, maxSize)
      }
      throw WireError.invalid("直播弹幕数据过大")
    }
  }
  #if canImport(Compression)
    private static func brotliStream(_ input: Data, limit: Int) throws -> Data {
      let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
      defer { stream.deallocate() }
      guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK
      else { throw WireError.invalid("无法解压直播帧") }
      defer { compression_stream_destroy(stream) }
      let chunk = 32 * 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
      defer { buffer.deallocate() }
      var output = Data()
      return try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data in
        stream.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
        stream.pointee.src_size = source.count
        while true {
          let unread = stream.pointee.src_size
          stream.pointee.dst_ptr = buffer
          stream.pointee.dst_size = chunk
          let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
          let produced = chunk - stream.pointee.dst_size
          output.append(buffer, count: produced)
          guard output.count <= limit else { throw WireError.invalid("直播弹幕数据过大") }
          if status == COMPRESSION_STATUS_END, !output.isEmpty { return output }
          // Still decoding only while it makes progress; a truncated frame stops here.
          guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.pointee.src_size < unread else {
            throw WireError.invalid("Brotli 直播帧无效")
          }
        }
      }
    }
  #endif
}
