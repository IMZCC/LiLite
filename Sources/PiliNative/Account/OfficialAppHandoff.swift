import UIKit

/// Both apps register bilibili:. If iOS routes our request back to us, keep the current flow open.
@MainActor final class OfficialAppHandoff {
  static let shared=OfficialAppHandoff()
  private var pending:(id:UUID,url:URL,failed:()->Void)?
  private var release:Task<Void,Never>?
  func open(_ website:URL,onFailure:@escaping ()->Void){
    guard website.scheme=="https",let h=website.host?.lowercased(),h=="bilibili.com" || h.hasSuffix(".bilibili.com"),
      website.user==nil,website.password==nil,website.port==nil || website.port==443 else{onFailure();return}
    let id=UUID()
    var link=URLComponents();link.scheme="bilibili";link.host="browser"
    link.queryItems=[.init(name:"url",value:website.absoluteString)]
    guard let url=link.url else{onFailure();return}
    release?.cancel();pending=(id,url,onFailure)
    release=Task{[weak self] in
      do{try await Task.sleep(for:.seconds(8))}catch{return}
      if self?.pending?.id==id {self?.pending=nil}
    }
    UIApplication.shared.open(website,options:[.universalLinksOnly:true]) { [weak self] accepted in
      guard let self,self.pending?.id==id else{return}
      if accepted { self.pending=nil;self.release?.cancel();return }
      UIApplication.shared.open(url) { [weak self] ok in
        guard !ok,let self,self.pending?.id==id else{return}
        self.pending=nil;self.release?.cancel();onFailure()
      }
    }
  }
  func returnedToSender(_ url:URL)->Bool {
    guard let item=pending,item.url==url else{return false}
    pending=nil;release?.cancel();item.failed();return true
  }
}
