import Foundation

enum ReplyMath {
  struct Span { let range: NSRange, source: String, display: String }
  struct Bad: Error {}
  static func spans(_ text: String) -> ([Span], [String]) {
    let chars = Array(text)
    let offset = chars.reduce(into: [0]) { $0.append($0.last! + (String($1) as NSString).length) }
    var i = 0
    var results = [Span]()
    var warnings = [String]()
    while i < chars.count {
      if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
        i += 2
        continue
      }
      guard chars[i] == "$" else {
        i += 1
        continue
      }
      let start = i
      let count = (i + 1 < chars.count && chars[i + 1] == "$") ? 2 : 1
      i += count
      var k = i
      var closed = false
      while k < chars.count {
        if chars[k] == "\\", k + 1 < chars.count, chars[k + 1] == "$" {
          k += 2
          continue
        }
        if chars[k] == "$" && (count == 1 || (k + 1 < chars.count && chars[k + 1] == "$")) {
          closed = true
          break
        }
        k += 1
      }
      guard closed else {
        i = start + 1
        continue
      }
      let end = k + count
      let source = String(chars[start..<end])
      i = end
      guard k > start + count, k - start <= 8192 else { continue }
      do {
        var p = Parser(chars: Array(chars[start + count..<k]))
        let display = try p.sequence(depth: 0).replacingOccurrences(
          of: " +", with: " ", options: .regularExpression)
        warnings += p.warnings
        results.append(
          .init(
            range: .init(location: offset[start], length: offset[end] - offset[start]),
            source: source, display: display))
      } catch { warnings.append("公式结构不完整") }
    }
    return (results, warnings)
  }
  private struct Parser {
    let chars: [Character]
    var pos = 0, warnings = [String]()
    mutating func sequence(until close: Character? = nil, depth: Int) throws -> String {
      guard depth < 48 else { throw Bad() }
      var out = ""
      while pos < chars.count {
        if let close, chars[pos] == close {
          pos += 1
          return out
        }
        if chars[pos] == "}" { throw Bad() }
        out += try atom(depth: depth)
      }
      if close != nil { throw Bad() }
      return out
    }
    mutating func atom(depth: Int) throws -> String {
      guard depth < 48, pos < chars.count else { throw Bad() }
      let c = chars[pos]
      pos += 1
      if c == "{" { return try sequence(until: "}", depth: depth + 1) }
      if c == "^" || c == "_" { return Self.script(try atom(depth: depth + 1), sup: c == "^") }
      guard c == "\\" else { return String(c) }
      guard pos < chars.count else { return "\\" }
      var name = ""
      if chars[pos].isLetter {
        while pos < chars.count && chars[pos].isLetter {
          name.append(chars[pos])
          pos += 1
        }
      } else {
        name = String(chars[pos])
        pos += 1
      }
      if name == "\n" || name == "\r" { return " " }
      if name.first?.isLetter == true, pos < chars.count, chars[pos] == " ",
        ReplyMathGlyphs.sym[name] == nil
      {
        pos += 1
      }
      if name == "begin" {
        let env = try atom(depth: depth + 1)
        let ending = Array("\\end{" + env + "}")
        var rows = [[String]]()
        var row = [String]()
        var cell = ""
        while pos < chars.count {
          if chars[pos...].starts(with: ending) {
            pos += ending.count
            row.append(cell)
            rows.append(row)
            if !ReplyMathGlyphs.matrixEnvs.contains(env) {
              return rows.map { $0.joined(separator: "&") }.joined(separator: "\\")
            }
            return Self.matrix(rows)
          }
          if chars[pos] == "&" {
            row.append(cell)
            cell = ""
            pos += 1
            continue
          }
          if chars[pos] == "\\", pos + 1 < chars.count, chars[pos + 1] == "\\" {
            row.append(cell)
            rows.append(row)
            row = []
            cell = ""
            pos += 2
            continue
          }
          cell += try atom(depth: depth + 1)
        }
        throw Bad()
      }
      if name == "end" { throw Bad() }
      if let s = ReplyMathGlyphs.sym[name] ?? ReplyMathGlyphs.voidCmds[name] { return s }
      if name.count == 1, "{}&%#_$[]~ \\".contains(name) { return name }
      var opt: String?
      var args = [String]()
      if name == "sqrt", pos < chars.count, chars[pos] == "[" {
        pos += 1
        opt = try sequence(until: "]", depth: depth + 1)
      }
      while pos < chars.count && chars[pos] == "{" { args.append(try atom(depth: depth + 1)) }
      if name == "sqrt", args.isEmpty {
        while pos < chars.count && chars[pos] == " " { pos += 1 }
        if pos < chars.count { args.append(try atom(depth: depth + 1)) }
      }
      let a = args.first ?? ""
      let b = args.dropFirst().first ?? ""
      if let style = ReplyMathGlyphs.styleCmds[name] { return Self.styled(a, style) }
      if ReplyMathGlyphs.plainCmds.contains(name) { return a }
      if let accent = ReplyMathGlyphs.accents[name] { return a + accent }
      switch name {
      case "frac", "dfrac": return Self.wrap(a) + "/" + Self.wrap(b)
      case "sqrt":
        return (opt.map { Self.script($0, sup: true) } ?? "") + "√"
          + (a.unicodeScalars.count == 1
            || (!a.isEmpty && a.utf8.allSatisfy { (48...57).contains($0) }) ? a : "(" + a + ")")
      case "color": return args.dropFirst().joined()
      case "binom", "dbinom", "tbinom": return "C(" + a + ", " + b + ")"
      case "bmod": return "mod "
      case "pmod": return "(mod " + a + ")"
      case "det": return a.isEmpty ? "det" : "det(" + a + ")"
      case "overset", "stackrel", "underset": return b + "(" + a + ")"
      default:
        warnings.append("\\" + name)
        return "\\" + name + (args.isEmpty ? " " : args.map { "{" + $0 + "}" }.joined())
      }
    }
    static func wrap(_ v: String) -> String {
      guard v.count > 1, v.contains(where: { "+-= /".contains($0) }) else { return v }
      if v.first == "(", v.last == ")" {
        var level = 0
        var wrapped = true
        for (i, c) in v.enumerated() {
          if c == "(" { level += 1 }
          if c == ")" { level -= 1 }
          if level == 0 && i < v.count - 1 {
            wrapped = false
            break
          }
        }
        if wrapped { return v }
      }
      return "(" + v + ")"
    }
    static func styled(_ s: String, _ kind: String) -> String {
      guard let (lo, up) = ReplyMathGlyphs.offsets[kind] else { return s }
      return s.unicodeScalars.map { u in
        let n = u.value
        let v: UInt32?
        if let special = ReplyMathGlyphs.substitutes[kind]?[String(u)] {
          v = special
        } else if (65...90).contains(n) {
          v = lo + n - 65
        } else if (97...122).contains(n) {
          v = up + n - 97
        } else if (48...57).contains(n), let d = ReplyMathGlyphs.digits[kind] {
          v = d + n - 48
        } else {
          v = nil
        }
        return v.flatMap(UnicodeScalar.init).map(String.init) ?? String(u)
      }.joined()
    }
    static func script(_ v: String, sup: Bool) -> String {
      let map = sup ? ReplyMathGlyphs.supMap : ReplyMathGlyphs.subMap
      let chars = v.map(String.init)
      var out = ""
      for c in chars {
        if let g = map[c] {
          out += g
          continue
        }
        if sup && chars.count == 1, let n = c.unicodeScalars.first?.value {
          for (_, offset) in ReplyMathGlyphs.offsets {
            if n >= offset.0, n < offset.0 + 26, let u = UnicodeScalar(n - offset.0 + 65),
              let glyph = map[String(u)]
            {
              return glyph
            }
            if n >= offset.1, n < offset.1 + 26, let u = UnicodeScalar(n - offset.1 + 97),
              let glyph = map[String(u)]
            {
              return glyph
            }
          }
        }
        if chars.count == 1, let first = v.first, !first.isNumber && !first.isLetter { return v }
        return (sup ? "^(" : "_(") + v + ")"
      }
      return out
    }
    static func matrix(_ rows: [[String]]) -> String {
      let all = rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }.filter {
        r in r.contains { !$0.isEmpty }
      }
      if all.count <= 1 { return all.first.map { "[ " + $0.joined(separator: " ") + " ]" } ?? "" }
      let n = all.map(\.count).max() ?? 0
      guard n <= 128, all.count <= 128 else {
        return all.map { $0.joined(separator: " ") }.joined(separator: "\n")
      }
      let w = (0..<n).map { i in all.map { r in i < r.count ? r[i].utf16.count : 0 }.max() ?? 0 }
      let pad = "\u{2007}"
      let width = w.reduce(0, +) + n * 4 + max(0, n - 1)
      guard width * all.count < 50000 else {
        return all.map { $0.joined(separator: " ") }.joined(separator: "\n")
      }
      var lines = ["┌" + String(repeating: pad, count: width) + "┐"]
      for r in all {
        let cells = (0..<n).map { i -> String in
          let v = i < r.count ? r[i] : ""
          let space = w[i] + 4 - v.utf16.count
          let left = space / 2
          return String(repeating: pad, count: left) + v
            + String(repeating: pad, count: space - left)
        }
        lines.append("│" + cells.joined(separator: pad) + "│")
      }
      lines.append("└" + String(repeating: pad, count: width) + "┘")
      return lines.joined(separator: "\n")
    }
  }
}
extension ReplyDraft {
  static let mathKind = 87
  var showingMath: Bool { markedRanges.contains { $0.kind == Self.mathKind } }
  mutating func toggleMath() -> String? {
    if showingMath {
      for e in markedRanges.reversed() where e.kind == Self.mathKind {
        replace(e.range, with: e.source)
      }
      return nil
    }
    let marked = markedRanges
    let (spans, warnings) = ReplyMath.spans(text)
    let eligible = spans.filter { s in
      !marked.contains { NSIntersectionRange($0.range, s.range).length > 0 }
    }
    for s in eligible.reversed() {
      replace(
        s.range, with: s.display, url: s.display, kind: Self.mathKind, business: s.source,
        addSpace: false)
    }
    if !warnings.isEmpty { return "已保留未识别的公式：" + warnings.prefix(3).joined(separator: "、") }
    return eligible.isEmpty ? "请用 $ 包住公式" : nil
  }
}
