import Foundation
@main enum Extract {
  static func main() throws {
    let info = BackupFormat.fields.map { ["key":$0.key,"path":$0.path.joined(separator:"/")] }
    try JSONEncoder().encode(info).write(to: URL(fileURLWithPath:CommandLine.arguments[1]))
  }
}
