# video_keyframe_extractor

一个同时支持 Android & iOS 的 Flutter 插件，用于高性能抽取视频关键帧/等间隔帧。
在“全片稀疏抽帧（如 8～16 张封面）”场景下，iOS 端默认采用并行 AVAssetImageGenerator + 无限容差 + 预热 + HEIC 编码的极速策略；Android 端提供 fastMode 预设（关键帧优先 + 并发切片 + 像素下压 + 减少 I/O），常见配置可实现亚秒级出图。

## ✨ 功能特性

跨平台一致：Android（Kotlin）& iOS（Swift）双端实现，方法参数一致
高性能：
iOS：并行 Generator（2～4 路）/ 分片 Reader，自适应选择；HEIC 编码更小更快
Android：CLOSEST_SYNC、分片并发、像素/质量下压、缓冲复用、I/O 优化
可控质量：targetWidth/targetHeight 或 maxDecodePixels 控制分辨率，JPEG 质量可选
实用工程能力：分页抽帧、任务取消、缓存清理、详细中文日志与耗时埋点
## ✨ 参数
```dart
class VKExtractOptions {
  final int count;                // 抽帧数量（建议 ≤20）
  final int? targetWidth;         // 目标宽（与 targetHeight 一起生效）
  final int? targetHeight;        // 目标高
  final int? maxDecodePixels;     // 解码像素上限（越小越快，如 200_000）
  final VKOutputMode outputMode;  // bytes | files
  final bool preferClosestSync;   // Android: 关键帧优先
  final int? pageStart;           // 分页起点（默认 0）
  final int? pageSize;            // 分页大小（默认 count）
  final String? taskId;           // 任务 ID（用于取消/清理）
  final int? quality;             // Android: JPEG 质量（40..100，建议 ≤70）
  final int? maxConcurrency;      // Android: 最大并发（1..6，建议 ≤3）
  final bool? fastMode;           // Android: 极速预设

  const VKExtractOptions({...});

  /// 极速预设（推荐）
  factory VKExtractOptions.fast({
    required int count,
    String? taskId,
    int quality = 70,
    int maxDecodePixels = 200000,
    int maxConcurrency = 3,
  });
}

```
## ✨ 方法
```dart
class VideoKeyframeExtractor {
  Future<String?> getPlatformVersion();

  static Future<List<dynamic>> extractKeyFrames({
    required String path,
    required VKExtractOptions options,
  });

  static Future<void> cancel({required String taskId});
  static Future<void> clearCache({required String taskId});
  static Future<void> clearAllCaches();
}

```

## 🚀 使用示例
### 1) 极速预设：12 张封面（推荐起步）
```dart
final res = await VideoKeyframeExtractor.extractKeyFrames(
  path: '/path/to/video.mp4',
  options: VKExtractOptions(
    count: 12,
    outputMode: VKOutputMode.files,
    maxDecodePixels: 200000,
    // Android: I 帧优先
    preferClosestSync: true,
    pageStart: 0,
    pageSize: 12,
  ),
);
// res: List<String>（文件路径）

```
### 2) 直接写入文件（缓存目录）
```dart
final res = await VideoKeyframeExtractor.extractKeyFrames(
  path: '/path/to/video.mp4',
  options: VKExtractOptions(
    count: 12,
    outputMode: VKOutputMode.files,
    maxDecodePixels: 200000,
    // Android: I 帧优先
    preferClosestSync: true,
    pageStart: 0,
    pageSize: 12,
  ),
);
// res: List<String>（文件路径）

```
### 3) 自定义尺寸/质量/并发
```dart
final res = await VideoKeyframeExtractor.extractKeyFrames(
  path: '/path/to/video.mov',
  options: VKExtractOptions(
    count: 8,
    outputMode: VKOutputMode.bytes,
    targetWidth: 720, targetHeight: 1280, // 指定此对覆盖 maxDecodePixels
    maxDecodePixels: 180000,
    preferClosestSync: true, // Android
    quality: 65,             // Android
    maxConcurrency: 3,       // Android
  ),
);

```
### 4) 取消与清理
```dart
final taskId = 'job_${DateTime.now().millisecondsSinceEpoch}';

final future = VideoKeyframeExtractor.extractKeyFrames(
  path: path,
  options: VKExtractOptions.fast(count: 12, taskId: taskId),
);

// 中途取消
await VideoKeyframeExtractor.cancel(taskId: taskId);

// 清理本次任务缓存
await VideoKeyframeExtractor.clearCache(taskId: taskId);

// 清理所有缓存
await VideoKeyframeExtractor.clearAllCaches();

```
