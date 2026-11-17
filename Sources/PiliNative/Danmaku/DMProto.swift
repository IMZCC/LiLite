import Foundation

/// Fields are the DmSegMobileReply / DanmakuElem wire contracts from
/// lib/grpc/bilibili/community/service/dm/v1.pbjson.dart.
enum DMProto {
  enum Invalid: Error { case malformed }
  struct Reader {
    let bytes: [UInt8]
    var i: Int = 0
    let end: Int
    mutating func integer() throws -> UInt64 {
      var result: UInt64 = 0
      for shift in stride(from: 0, to: 64, by: 7) {
        guard i < end else { throw Invalid.malformed }
        let b = bytes[i]
        i += 1
        if shift == 63 && b > 1 { throw Invalid.malformed }
        result |= UInt64(b & 127) << shift
        if b < 128 { return result }
      }
      throw Invalid.malformed
    }
    mutating func skip(_ n: Int) throws {
      guard n >= 0, n <= end - i else { throw Invalid.malformed }
      i += n
    }
    mutating func slice() throws -> Reader {
      let size = try integer()
      guard size <= end - i else { throw Invalid.malformed }
      let start = i
      i += Int(size)
      return Reader(bytes: bytes, i: start, end: i)
    }
    mutating func skipWire(_ wire: UInt64) throws {
      switch wire {
      case 0: _ = try integer()
      case 1: try skip(8)
      case 2: _ = try slice()
      case 5: try skip(4)
      default: throw Invalid.malformed
      }
    }
  }
  struct Page {let items:[Bullet],state:Int;var closed:Bool{state==1}}
  static func parse(_ data:Data)throws->[Bullet]{try page(data).items}
  /// Exactly the fields set by DmGrpc.dmSegMobile (not a raw video or message ID).
  static func request(cid:Int64,index:Int)throws->Data{
    guard cid>0,index>0,index<=1_000_000 else{throw Invalid.malformed}
    func varint(_ value:UInt64)->[UInt8]{var x=value,b=[UInt8]();while x>=128{b.append(UInt8(x&127)|128);x >>= 7};b.append(UInt8(x));return b}
    return Data([16]+varint(UInt64(cid))+[24,1,32]+varint(UInt64(index)))
  }
  static func page(_ data: Data) throws -> Page {
    guard data.count<=8*1024*1024 else{throw Invalid.malformed}
    var state=0
    let bytes = Array(data)
    var r = Reader(bytes: bytes, end: bytes.count)
    var out: [Bullet] = []
    while r.i < r.end {
      let key = try r.integer()
      guard key != 0 else{throw Invalid.malformed};if key==16{state=Int(truncatingIfNeeded:try r.integer());continue}
      guard key == 10 else {
        try r.skipWire(key & 7)
        continue
      }
      guard out.count<100000 else{throw Invalid.malformed}
      var elem = try r.slice()
      var t: UInt64 = 0
      var mode = 1
      var font = 25.0
      var color = 0xffffff
      var text = ""
      var sender: String?
      var entryID: Int64?
      var weight: Int?
      var colorType: Int?
      var likes: Int?
      while elem.i < elem.end {
        let tag = try elem.integer()
        switch tag {
        case 8: entryID = Int64(bitPattern: try elem.integer())
        case 50:
          let s = try elem.slice()
          sender = String(decoding: bytes[s.i..<s.end], as: UTF8.self)
        case 72: weight = Int(truncatingIfNeeded: try elem.integer())
        case 120: likes = Int(truncatingIfNeeded: try elem.integer())
        case 192: colorType = Int(truncatingIfNeeded: try elem.integer())
        case 16: t = try elem.integer()
        case 24: mode = Int(truncatingIfNeeded: try elem.integer())
        case 32: font = Double(try elem.integer())
        case 40: color = Int(truncatingIfNeeded: try elem.integer())
        case 58:
          let s = try elem.slice()
          text = String(decoding: bytes[s.i..<s.end], as: UTF8.self)
        default: try elem.skipWire(tag & 7)
        }
      }
      guard text.utf8.count<65536 else{continue}
      if mode == 7, let special = SpecialBullet(text) {
        out.append(
          .init(
            time: Double(t) / 1000, mode: mode, rgb: color, text: special.text, wireText: text, fontSize: font,
            special: special, sender: sender, entryID: entryID, weight: weight,
            colorType: colorType, likes: likes))
      } else if ((1...6).contains(mode) || mode==8 || mode==9), !text.isEmpty {
        out.append(
          .init(
            time: Double(t) / 1000, mode: mode, rgb: color, text: text, fontSize: font,
            sender: sender, entryID: entryID, weight: weight, colorType: colorType, likes: likes))
      }
    }
    return Page(items:out.sorted{$0.time<$1.time},state:state)
  }
}
