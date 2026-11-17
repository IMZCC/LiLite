import SwiftUI
import UIKit

struct LiveEmotePicker: View {
  let room:Int64,owner:String, choose:(LiveEmoji,Bool)->Void
  @Environment(\.dismiss) private var dismiss
  @State private var groups:[LiveEmoteChoices.Group]?
  @State private var index=0
  @State private var issue:String?
  @State private var retry=0
  var body:some View {
    VStack(spacing:0) {
      if let groups, groups.indices.contains(index) {
        let group=groups[index]
        ScrollView(.horizontal) {
          HStack(spacing:6) { ForEach(groups.indices,id:\.self){i in
            let p=groups[i]
            Button {withAnimation(.snappy(duration:0.2)){index=i}} label:{
              HStack(spacing:6) {
                if let url=p.current_cover.flatMap(GalleryPicture.source){
                  RemoteArtwork(url:url){$0.resizable().scaledToFit()} placeholder:{Color.clear}.frame(width:24,height:24)
                }
                Text(p.pkg_name ?? "表情包 \(i+1)").font(.footnote.weight(i==index ? .semibold:.regular))
              }
              .foregroundStyle(i==index ? Color.primary:Color.secondary)
              .padding(.horizontal,12).padding(.vertical,6)
              .background(i==index ? Color(uiColor:.tertiarySystemFill):Color.clear,in:Capsule())
            }.buttonStyle(.plain).accessibilityAddTraits(i==index ? .isSelected:[])
          }}.padding(.horizontal,16).padding(.vertical,8)
        }.scrollIndicators(.hidden)
        Divider()
        Text(group.insertsText ? "点按插入弹幕" : "点按发送表情").font(.caption).foregroundStyle(.tertiary).padding(.top,8)
        ScrollView {LazyVGrid(columns:[GridItem(.adaptive(minimum:62))],spacing:10){
          ForEach(group.rows){ e in
            Button { if e.available {choose(e,group.insertsText)} } label:{
              VStack(spacing:2){
                RemoteArtwork(url:e.url.flatMap(GalleryPicture.source)){$0.resizable().scaledToFit()} placeholder:{Color.clear}
                  .frame(width:min(96,max(38,CGFloat(e.width ?? 80)*0.475)),height:min(88,max(38,CGFloat(e.height ?? 80)*0.475)))
                Text(e.emoji ?? "表情").lineLimit(1).font(.caption2)
                if !e.available {Label(e.unlock_show_text ?? "未解锁",systemImage:"lock").font(.caption2)}
              }
            }.disabled(!e.available).contextMenu {
              if e.available {Button(group.insertsText ? "插入弹幕":"发送这个表情"){choose(e,group.insertsText)}}
            } preview:{EmoteMenuPreview(url:e.url.flatMap(GalleryPicture.source),name:e.emoji ?? "表情")}
          }
        }.padding()}
      } else if let issue {ContentUnavailableView{Label("表情未能加载",systemImage:"face.smiling")} description:{Text(issue)} actions:{Button("重试"){retry += 1}}}
      else if groups != nil {ContentUnavailableView("暂无可用表情",systemImage:"face.smiling")}
      else {ProgressView()}
    }.navigationTitle("直播表情").navigationBarTitleDisplayMode(.inline)
      .toolbar{ToolbarItem(placement:.confirmationAction){Button("关闭"){dismiss()}}}
      .presentationDetents([.medium,.large])
      .task(id:"\(room):\(owner):\(retry)"){
        groups=nil;issue=nil;index=0
        do {
          let response=try await BiliAPI.shared.liveEmoteGroups(room,owner:owner)
          try Task.checkCancellation();groups=response
        } catch {if !Task.isCancelled {issue=error.localizedDescription}}
      }
  }
}

struct LiveDraftField:UIViewRepresentable {
  @Binding var text:String
  @Binding var selection:NSRange?
  let focusCount:Int
  let submit:()->Void
  final class Coordinator:NSObject,UITextFieldDelegate {
    var owner:LiveDraftField;var focusCount=0;var updating=false
    init(_ owner:LiveDraftField){self.owner=owner}
    func textFieldShouldReturn(_ field:UITextField)->Bool {
      guard field.markedTextRange == nil else{return false}
      owner.submit();return false
    }
    @objc func changed(_ field:UITextField){owner.text=field.text ?? "";textFieldDidChangeSelection(field)}
    func textFieldDidChangeSelection(_ f:UITextField){
      guard !updating,f.isFirstResponder,let r=f.selectedTextRange else{return}
      let pos=f.offset(from:f.beginningOfDocument,to:r.start),len=f.offset(from:r.start,to:r.end)
      let value=NSRange(location:pos,length:len);if owner.selection != value {owner.selection=value}
    }
  }
  func makeCoordinator()->Coordinator{Coordinator(self)}
  func makeUIView(context:Context)->UITextField {
    let field=UITextField();field.borderStyle = .none;field.placeholder="发个弹幕呗~";field.delegate=context.coordinator
    field.returnKeyType = .send;field.enablesReturnKeyAutomatically=true;field.clearButtonMode = .whileEditing
    field.addTarget(context.coordinator,action:#selector(Coordinator.changed(_:)),for:.editingChanged)
    field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);return field
  }
  func updateUIView(_ f:UITextField,context:Context){
    let c=context.coordinator;c.owner=self;c.updating=true;defer{c.updating=false}
    if f.text != text {f.text=text
      if let r=selection,r.location>=0,r.length>=0,let s=f.position(from:f.beginningOfDocument,offset:r.location),
        let e=f.position(from:s,offset:r.length){f.selectedTextRange=f.textRange(from:s,to:e)}
    }
    if focusCount != c.focusCount {c.focusCount=focusCount;DispatchQueue.main.async { [weak f] in _=f?.becomeFirstResponder() }}
  }
}
