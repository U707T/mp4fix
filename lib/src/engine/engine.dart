/// MP4 无损修复引擎（纯 Dart，无 Flutter 依赖，可在任意平台运行）。
///
///  - [Mp4Inspect]：只读文件头与 moov 的健康检测（结构 / 交错距离 / faststart）；
///  - [Mp4Repair]：按时间重排音视频数据（无损）、moov 前置、丢弃尾部垃圾；
///    支持分片（fragmented）MP4 无损转换为标准 MP4；
///  - [SeekableInput] / [SyncSink]：随机读 / 顺序写抽象（文件、内存、WebDAV Range…）。
library;

export 'binary.dart';
export 'boxes.dart';
export 'mp4_fragments.dart';
export 'mp4_inspect.dart';
export 'mp4_repair.dart';
export 'seekable_input.dart';
