import SwiftUI

struct StaffCreditRow:View{
  let staff:VideoStaff
  var body:some View{
    HStack(spacing:9){
      SiteThumbnail(url:staff.face.flatMap(httpsURL)){$0.resizable().scaledToFill()}placeholder:{
        Image(systemName:"person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
      }.frame(width:36,height:36).clipShape(Circle())
        .overlay(alignment:.bottomTrailing){
          if let role=staff.official?.type,role>=0{
            Image(systemName:"checkmark.seal.fill").font(.caption2).symbolRenderingMode(.palette)
              .foregroundStyle(.white,role==0 ? .orange:.blue)
              .accessibilityLabel(staff.official?.desc ?? (role==0 ? "个人认证":"机构认证"))
          }
        }
      VStack(alignment:.leading,spacing:2){
        Text(staff.name ?? "创作者").foregroundStyle((staff.vip?.status ?? 0)>0 && staff.vip?.type==2 ? Color.pink:Color.primary)
        if let job=staff.title,!job.isEmpty{Text(job).font(.caption).foregroundStyle(.secondary)}
      }
      Spacer()
    }.contentShape(Rectangle())
  }
}
