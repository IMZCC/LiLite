import Foundation
import Darwin

/// DNS-SD only for the two device service types declared in Info.plist.
/// Use the peer address returned by the resolver, never an arbitrary URL from a TXT record.
@MainActor final class CastBonjour:NSObject,NetServiceBrowserDelegate,NetServiceDelegate {
  private var browsers:[NetServiceBrowser]=[]
  private var services:[String:NetService]=[:]
  private var sent=Set<String>()
  private let feed:AsyncThrowingStream<CastAdvertisement,Error>.Continuation
  private init(_ feed:AsyncThrowingStream<CastAdvertisement,Error>.Continuation){self.feed=feed}
  static func events()->AsyncThrowingStream<CastAdvertisement,Error>{
    let (stream,feed)=AsyncThrowingStream<CastAdvertisement,Error>.makeStream(bufferingPolicy:.bufferingNewest(96))
    let browser=CastBonjour(feed)
    let expiry=Task { @MainActor in
      browser.start()
      do {try await Task.sleep(for:.seconds(8))}catch{}
      browser.stop()
    }
    feed.onTermination={_ in expiry.cancel()}
    return stream
  }
  private func start(){
    for kind in ["_upnp._tcp.","_ssdp._udp."] {
      let b=NetServiceBrowser();b.delegate=self;browsers.append(b)
      b.searchForServices(ofType:kind,inDomain:"local.")
    }
  }
  private func stop(){
    for b in browsers {b.delegate=nil;b.stop()}
    for s in services.values {s.delegate=nil;s.stop()}
    browsers=[];services=[:];feed.finish()
  }
  private func key(_ s:NetService)->String{"bonjour:\(s.type):\(s.name)"}
  func netServiceBrowser(_ browser:NetServiceBrowser,didFind service:NetService,moreComing:Bool){
    let id=key(service)
    guard services.count < 64,services[id]==nil else{return}
    services[id]=service;service.delegate=self;service.resolve(withTimeout:4)
  }
  func netServiceBrowser(_ browser:NetServiceBrowser,didRemove service:NetService,moreComing:Bool){
    let id=key(service);services.removeValue(forKey:id)?.stop()
    if sent.remove(id) != nil {feed.yield(.init(location:nil,sender:"",udn:id,alive:false,age:0))}
  }
  func netServiceBrowser(_ browser:NetServiceBrowser,didNotSearch errorDict:[String:NSNumber]){
    browsers.removeAll{$0 === browser}
    if browsers.isEmpty {feed.finish(throwing:CastProblem.localPermission)}
  }
  func netServiceDidResolveAddress(_ service:NetService){
    let id=key(service)
    guard services[id] === service,!sent.contains(id),(1...65535).contains(service.port) else{return}
    let txt=service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
    let fields=txt.reduce(into:[String:String]()){result,pair in
      if pair.value.count<=2048,let text=String(data:pair.value,encoding:.utf8){result[pair.key.lowercased()]=text}
    }
    let name=service.hostName?.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
    for data in service.addresses ?? [] {
      var addr=sockaddr_storage()
      guard data.count>=MemoryLayout<sockaddr_in>.size && data.count<=MemoryLayout<sockaddr_storage>.size else{continue}
      _=withUnsafeMutableBytes(of:&addr){data.copyBytes(to:$0)}
      guard data.count>=Int(addr.ss_len),[AF_INET,AF_INET6].contains(Int32(addr.ss_family)),
        let peer=withUnsafePointer(to:&addr,{p in p.withMemoryRebound(to:sockaddr.self,capacity:1){CastLAN.numeric($0)}}),
        let url=CastBonjourLocation.description(peer:peer,name:name,port:service.port,tcp:service.type=="_upnp._tcp.",fields:fields)
      else{continue}
      sent.insert(id);feed.yield(.init(location:url,sender:peer,udn:id,alive:true,age:120));break
    }
  }
}
