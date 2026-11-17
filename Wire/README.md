# 私信、动态与直播协议

Swift 类型来自固定上游提交中的 Protobuf 描述符，并保留上游声明的字段编号、oneof、map 和跨文件引用。直播数据包使用系统 zlib，以及 Apple Compression 框架的 Brotli 解码；Linux 上的对照测试使用 libbrotlidec。业务代码位于主包，Wire 不依赖 Flutter 或 UIKit

在 WSL 使用 `/usr/bin/python3 ../Checks/generate_wire.py /path/to/protoc-gen-swift` 重新生成。生成器和运行库固定为 [Apple SwiftProtobuf 1.32.0](https://github.com/apple/swift-protobuf/tree/1.32.0)，许可见其 [Apache-2.0 LICENSE](https://github.com/apple/swift-protobuf/blob/1.32.0/LICENSE.txt)。包依赖固定到同一 Git 提交
