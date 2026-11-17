# 断续音频反馈后的 HLS / 时间线只读核查

审查基线 `e14b9cfdb`，本轮未修改播放源码、签收门或进行签名安装

检查实际链路：`DashBridge.index` → `SegmentIndex` / `LocalFragmentIndex` → `TrackIndex.playlist` → `serve/reply`，以及 `LocalMovieFragments`、转换后 `DecoderFragment`、`LegacyDURLPlaylist` / `LegacyMediaHTTP` 的边界和 Range 处理

## 真实临时媒体复现

使用合成连续正弦音频，运行生产 Swift 索引、经典 MP4 转分片及 HLS 清单方法；独立解析 `mdhd/tfdt/trun` 的每个样本时间和时长，再由 FFmpeg 实际解码生成的 HLS

| 输入 / 路径 | 分片 | 相邻时间线空洞 | EXTINF 最大误差 | HLS 与连续原文件 PCM |
| --- | --- | --- | --- | --- |
| AAC 44.1 kHz / DASH SIDX | 7 | 0 | 1.33e-15 秒 | 545792 样本，逐字节相等 |
| AAC 48 kHz / DASH SIDX | 7 | 0 | 1.33e-15 秒 | 593920 样本，逐字节相等 |
| ALAC 96 kHz / DASH SIDX | 7 | 0 | 1.33e-15 秒 | 1185120 样本，逐字节相等 |
| 经典 AAC 48 kHz / 生产 LocalMovieFragments | 7 | 0 | 1.33e-15 秒 | 592896 样本，逐字节相等 |

首段、中间段与最后短段均包含在以上比对中；逐样本解析没有发现内部或相邻片段的空洞、重复时段或 timescale 换算错误

另运行生产 `AudioSegment.c` 的 `volume=1` 与 `dynaudnorm`，输出经过生产 `DecoderFragment` 和转换模式 HLS 清单，各七段实际解码的首尾时间完全相接，`EXTINF` 最大误差同样为 1.33e-15 秒。这里检查时间线，不用音效处理后的波形与原始波形相等作为条件

ALAC 的 stream-copy packet dump 会把最后一个压缩 packet 的 duration 显示为零，直接据此计算会得到虚假的约 42ms 缝隙；核对实际解码 PCM 帧和分片样本表后不存在该缝隙。末尾 AAC 的编码填充也没有被当成中途丢样本

## HTTP 与并发

运行未修改的生产 `DashBridge.serve/reply` 方法，仅把 Network.framework connection、账号检查和字节来源替换为合成叶，交错发出 100 个并发请求

- 普通 GET、HEAD、前缀、后缀、开放结尾、超出末端的合法截断均返回精确字节
- HEAD 的 Content-Length 保留对应媒体或请求区间长度，响应体为空
- Content-Range 与请求范围一致，音视频 lane 和每个连接的响应没有交叉
- 越界及多区间返回 416，错误 token 返回 404，未支持的方法返回 405
- 状态分布：50 次 206、20 次 416、10 次 200、10 次 404、10 次 405

真实 `NWConnection` 的发送回调未在 Linux 执行；只读检查确认监听队列管理各连接/任务，响应使用独立 Data 并在发送完成后关闭连接，没有发现会反复切断有效音频区间的明确代码路径

`LegacyMediaHTTP` 的 Range、HEAD 和每连接任务也已逐项阅读；`LegacyDURLPlaylist` 的多 period、初始化片段更换、discontinuity 与无音轨 gap 是独立分支，本次没有把它们当成当前普通 DASH 音乐视频的已确认故障来源

临时合成媒体、生产方法驱动和结果保留在 WSL `SwiftUI-Noble:/tmp/pili-hls-audit-utee5gt1`，包括各路 `result.json`、`summary.json` 与 `http-result.json`

## 结论

上述 HLS、片段时间及 HTTP 路径没有复现反复断音，不据此修改这些源码。普通可解码音轨还可能进入 `PictureTimingRegistry` → 独立 PCM 时钟输出，后续工作转向该实际发声路径的供数、rate 切换与生命周期，由播放及音频代理交叉复核
