"""Generate Swift messages from the descriptor bytes published in PiliPlus 2.2.0.2.
No Dart or Flutter SDK is involved. Requires python3-protobuf and protoc-gen-swift 1.32.0.
"""
import argparse
import base64
import re
import subprocess
from collections import defaultdict
from pathlib import Path
from google.protobuf import descriptor_pb2 as desc
from google.protobuf import any_pb2, descriptor_pool
from google.protobuf.compiler import plugin_pb2 as plugin

ROOT = Path(__file__).resolve().parents[2]
BASE = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
OUT = ROOT / "Native/Wire/Sources/PiliWire/Generated"
IM = "bilibili.app.im.v1."
ROOTS = [IM + name for name in (
    "PinSessionReq PinSessionReply UnPinSessionReq UnPinSessionReply SessionUpdateReq SessionUpdateReply "
    "SessionMainReq SessionMainReply SessionSecondaryReq SessionSecondaryReply ClearUnreadReq "
    "ClearUnreadReply DeleteSessionListReq DeleteSessionListReply GetImSettingsReq GetImSettingsReply "
    "SetImSettingsReq SetImSettingsReply KeywordBlockingListReq KeywordBlockingListReply "
    "KeywordBlockingAddReq KeywordBlockingAddReply KeywordBlockingDeleteReq KeywordBlockingDeleteReply"
).split()] + ['bilibili.im.interfaces.v1.'+n for n in ['ReqSessionMsg','RspSessionMsg','ReqTotalUnread','RspTotalUnread','ReqShareList','RspShareList','ReqSendMsg','RspSendMsg']]
ROOTS += ["bilibili.app.interfaces.v1.SearchArchiveReq", "bilibili.app.interfaces.v1.SearchArchiveReply"]
ROOTS += ["bilibili.im.interfaces.v1.ReqSessionDetail","bilibili.im.type.SessionInfo"]
ROOTS += ["bilibili.community.service.dm.v1."+n for n in ["DmViewReq","DmViewReply"]]
ROOTS += ["bilibili.app.dynamic.v1."+n for n in ["DynRedReq","DynRedReply"]]
ROOTS += ["bilibili.app.dynamic.v2."+n for n in "LikeListReq LikeListReply RepostListReq RepostListRsp OpusSpaceFlowReq OpusSpaceFlowResp".split()]
ROOTS += ["bilibili.main.community.reply.v1."+n for n in "MainListReq MainListReply DetailListReq DetailListReply DialogListReq DialogListReply FoldListReq FoldListResp SearchItemReq SearchItemReply TranslateReplyReq TranslateReplyResp".split()]
ROOTS += ["bilibili.rpc.Status", "bilibili.metadata.Metadata", "bilibili.metadata.device.Device"]
ROOTS += ["bilibili.app.listener.v1."+n for n in "PlaylistReq PlaylistResp PlayURLReq PlayURLResp ThumbUpReq ThumbUpResp TripleLikeReq TripleLikeResp CoinAddReq CoinAddResp".split()]
BLOCK = re.compile(r"/// Descriptor for " + chr(96) + r"([^" + chr(96)+r"]+)"+chr(96)+r"\. Decode as a "+chr(96)+r"google\.protobuf\.(EnumDescriptorProto|DescriptorProto)"+chr(96)+r"\.\s*final [^=]+?=\s*\$convert\s*\.base64Decode\((.*?)\);", re.S)
def source(path):
    return subprocess.check_output(["git","-C",str(ROOT),"show",BASE+":"+path]).decode()
def generate(executable,check=False):
    files, by_name, needed, imports = {}, {}, defaultdict(set), defaultdict(set)
    scanned=set()
    def scan(path):
        if path in scanned: return
        scanned.add(path)
        dart=source("lib/grpc/"+path.replace(".proto",".pb.dart"))
        entry=source("lib/grpc/"+path.replace(".proto",".pbjson.dart"))
        package=re.search(r"PackageName\(\s*(?:_omitMessageNames\s*\?\s*''\s*:\s*)?'([^']+)'",dart)
        if not package: raise ValueError("no package in "+path)
        pkg=package[1]
        files[path]=desc.FileDescriptorProto(name=path,package=pkg,syntax="proto3")
        files[path].options.swift_prefix="PiliIM_" if pkg==IM[:-1] else "Pili"+"".join(s.title() for s in pkg.split("."))+"_"
        for name,kind,chunks in BLOCK.findall(entry):
            d=desc.EnumDescriptorProto() if kind=="EnumDescriptorProto" else desc.DescriptorProto()
            d.ParseFromString(base64.b64decode("".join(re.findall(r"'([^']*)'",chunks)),validate=True))
            by_name[pkg+"."+name]=(path,d)
        for dep in re.findall(r"import '([^']+\.pb\.dart)'",dart):
            if dep.startswith('package:protobuf/well_known_types/'):continue  # Only included fields must resolve in include().
            import posixpath
            dep=posixpath.normpath(posixpath.join(posixpath.dirname(path),dep)).replace(".pb.dart",".proto")
            if dep.startswith("package:") or dep.startswith(".."):raise ValueError(dep)
            scan(dep)
    scan("bilibili/app/im/v1.proto")
    scan("bilibili/im/interfaces/v1.proto")
    scan("bilibili/app/dynamic/v2.proto")
    scan("bilibili/app/dynamic/v1.proto")
    scan("bilibili/community/service/dm/v1.proto")
    scan("bilibili/main/community/reply/v1.proto")
    scan("bilibili/rpc.proto")
    scan("bilibili/metadata.proto")
    scan("bilibili/metadata/device.proto")
    scan("bilibili/app/listener/v1.proto")
    # Dart's hasGoodsItemId/hasGoodsPrefetchedCache distinguish omitted fields from
    # present defaults. Preserve that observation in Swift without changing wire tags.
    _, url_message = by_name["bilibili.main.community.reply.v1.Url"]
    extra = next(m for m in url_message.nested_type if m.name == "Extra")
    for field in extra.field:
        if field.name in {"goods_item_id", "goods_prefetched_cache"} and not field.HasField("oneof_index"):
            field.oneof_index = len(extra.oneof_decl)
            extra.oneof_decl.add(name="_"+field.name)
            field.proto3_optional = True
    def include(name):
        path,d=by_name[name]
        if name in needed[path]:return
        needed[path].add(name)
        if isinstance(d,desc.DescriptorProto):
            def walk(m):
                for field in m.field:
                    dep=field.type_name.lstrip(".")
                    if not dep:continue
                    if dep=="google.protobuf.Any":imports[path].add("google/protobuf/any.proto");continue
                    if dep.startswith(name+"."):continue
                    # A field may refer to nested types within a different top-level message.
                    while dep not in by_name:
                        if "." not in dep:raise ValueError("missing field type "+field.type_name)
                        dep=dep.rsplit(".",1)[0]
                    other=by_name[dep][0]
                    if path!=other:imports[path].add(other)
                    include(dep)
                for child in m.nested_type:walk(child)
            walk(d)
    for name in ROOTS:include(name)
    req=plugin.CodeGeneratorRequest(parameter="Visibility=Public,FileNaming=PathToUnderscores")
    done=set()
    def emit(path):
        if path in done:return
        done.add(path)
        if path=="google/protobuf/any.proto":
            req.proto_file.add().ParseFromString(any_pb2.DESCRIPTOR.serialized_pb);return
        for dep in sorted(imports[path]):emit(dep)
        f=files[path];f.dependency.extend(sorted(imports[path]))
        for name in sorted(needed[path]):
            d=by_name[name][1]
            (f.enum_type if isinstance(d,desc.EnumDescriptorProto) else f.message_type).add().CopyFrom(d)
        req.proto_file.add().CopyFrom(f);req.file_to_generate.append(path)
    for path in sorted(needed):emit(path)
    pool=descriptor_pool.DescriptorPool()
    for schema in req.proto_file:
        # Older well-known descriptor sets do not carry the json_name normally filled by protoc.
        def add_json_names(message):
            for field in message.field:
                if not field.HasField("json_name"):
                    name="";upper=False
                    for ch in field.name:
                        if ch=="_":upper=True;continue
                        name+=ch.upper() if upper else ch;upper=False
                    field.json_name=name
            for nested in message.nested_type:add_json_names(nested)
        for message in schema.message_type:add_json_names(message)
        try:pool.AddSerializedFile(schema.SerializeToString())
        except Exception as exc:raise ValueError(f"invalid assembled schema: {schema.name}: {exc}") from exc
    res=plugin.CodeGeneratorResponse.FromString(subprocess.check_output([executable],input=req.SerializeToString()))
    if res.error:raise RuntimeError(res.error)
    OUT.mkdir(parents=True,exist_ok=True)
    for file in res.file:
        if "/" in file.name or not file.name.endswith(".pb.swift"):raise ValueError(file.name)
        if check:
            if (OUT/file.name).read_text(encoding="utf-8") != file.content:raise ValueError("changed generated source: "+file.name)
        else:(OUT/file.name).write_text(file.content,encoding="utf-8",newline="\n")
    if {f.name for f in OUT.glob("*.pb.swift")}!={f.name for f in res.file}:raise ValueError("stale generated file")
    print("Generated",sum(len(v) for v in needed.values()),"upstream messages, enums and dependencies in",len(res.file),"files")
if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("protoc_gen_swift");p.add_argument("--check",action="store_true");args=p.parse_args()
    generate(args.protoc_gen_swift,args.check)
