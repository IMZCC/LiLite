import Foundation
import SwiftSyntax
import SwiftParser

/// Extract genuine SwiftUI control labels and bindings using the Swift toolchain parser.
final class Reader: SyntaxVisitor {
  let file: String
  var result: [[String:Any]] = []
  init(file:String) { self.file=file; super.init(viewMode:.sourceAccurate) }
  override func visit(_ node:FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    let type = node.calledExpression.trimmedDescription
    // SettingToggle / SettingStepper / SettingSlider (Settings/SettingsKit.swift) take the title
    // as their first argument, just like the system controls.
    let accepted=["Toggle","Stepper","Picker","Menu","TextField","NavigationLink","LabeledContent","Button","Section","ColorPicker","DatePicker","SettingToggle","SettingStepper","SettingSlider"]
    guard accepted.contains(type) else { return .visitChildren }
    var cursor=Syntax(node).parent
    var owner="", skip=false, ownModifier=true
    var anchor: String?
    while let a=cursor {
      if let parent=a.as(StructDeclSyntax.self) { owner=parent.name.text;break }
      if a.is(ClosureExprSyntax.self) { ownModifier=false }
      if let fn=a.as(FunctionCallExprSyntax.self) {
        let base=fn.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text ?? fn.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        if ownModifier, anchor == nil, base == "settingAnchor",
          let value=fn.arguments.first?.expression.as(StringLiteralExprSyntax.self),
          value.segments.count == 1, let segment=value.segments.first?.as(StringSegmentSyntax.self)
        { anchor=segment.content.text }
        let inArguments = node.positionAfterSkippingLeadingTrivia.utf8Offset >= fn.calledExpression.endPositionBeforeTrailingTrivia.utf8Offset
        if inArguments && ["confirmationDialog","alert","contextMenu","toolbar","swipeActions","Menu","NavigationLink","ForEach"].contains(base ?? "") { skip=true }
      }
      cursor=a.parent
    }
    guard !skip, !owner.isEmpty else {return .visitChildren}
    let expr=node.arguments.first?.expression.trimmedDescription ?? ""
    let showsOwn = expr.hasPrefix("\"")
    let separateLabel=node.additionalTrailingClosures.first { $0.label.text == "label" }?.closure.trimmedDescription
    let insideLabel = separateLabel ?? node.trailingClosure?.trimmedDescription ?? ""
    let tex=showsOwn ? expr : insideLabel
    let pattern=showsOwn ? #""([^"\\\n]*[\p{Han}a-zA-Z][^"\\\n]*)"# : #"(?:Text|Label|LabeledContent)\(\s*"([^"\\\n]*[\p{Han}a-zA-Z][^"\\\n]*)"#
    guard let raw=tex.range(of:pattern,options:.regularExpression),let quote=tex[raw].firstIndex(of:"\"") else{return .visitChildren}
    let r=quote..<raw.upperBound
    var title=String(tex[r].dropFirst())

    title=title.trimmingCharacters(in:CharacterSet(charactersIn:" ··：:"))
    guard !title.isEmpty,title.count<=60 else{return .visitChildren}
    var row: [String:Any] = ["file":file,"owner":owner,"kind":type,"label":title,"start":node.positionAfterSkippingLeadingTrivia.utf8Offset,"offset":node.endPositionBeforeTrailingTrivia.utf8Offset,"expr":String(node.trimmedDescription.prefix(260))]
    if let anchor { row["anchor"]=anchor }
    result.append(row)
    return .visitChildren
  }
}

/// Resolve only named, literal static strings from this checkout, never computed properties.
final class LiteralKeys: SyntaxVisitor {
  var result: [[String:String]] = []
  init() { super.init(viewMode:.sourceAccurate) }
  override func visit(_ node:VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.modifiers.contains(where: { $0.name.text == "static" }) else { return .visitChildren }
    var cursor=Syntax(node).parent
    var owners=[String]()
    while let parent=cursor {
      if let value=parent.as(StructDeclSyntax.self) { owners.append(value.name.text) }
      else if let value=parent.as(EnumDeclSyntax.self) { owners.append(value.name.text) }
      else if let value=parent.as(ClassDeclSyntax.self) { owners.append(value.name.text) }
      else if let value=parent.as(ExtensionDeclSyntax.self) { owners.append(value.extendedType.trimmedDescription) }
      cursor=parent.parent
    }
    guard !owners.isEmpty else { return .visitChildren }
    for binding in node.bindings {
      guard let name=binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
        let value=binding.initializer?.value.as(StringLiteralExprSyntax.self),
        value.segments.count == 1, let text=value.segments.first?.as(StringSegmentSyntax.self),
        !text.content.text.contains("\\") else { continue }
      result.append(["name":(Array(owners.reversed())+[name]).joined(separator:"."),"value":text.content.text])
    }
    return .visitChildren
  }
}
@main struct Scan {
 static func main() throws {
  let arguments=Array(CommandLine.arguments.dropFirst())
  if arguments.first == "--constants" {
    var all=[[String:String]]()
    for file in arguments.dropFirst() {
      let reader=LiteralKeys()
      reader.walk(Parser.parse(source:try String(contentsOfFile:file,encoding:.utf8)))
      all += reader.result
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:all))
    return
  }
  var all:[[String:Any]]=[]
  for file in arguments {
    let r=Reader(file:file)
    r.walk(Parser.parse(source:try String(contentsOfFile:file,encoding:.utf8)))
    all += r.result
  }
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:all))
 }
}
