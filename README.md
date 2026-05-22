# brighton_video_keyframe_extractor

一个同时支持 Android 和 iOS 的 Flutter 插件，用于高性能抽取视频关键帧、获取封面图以及读取媒体信息。

这个插件主要面向“全片稀疏抽帧”场景，例如从一段视频中快速生成 8 到 16 张封面图。在常见配置下：

- iOS 侧默认使用并行 `AVAssetImageGenerator`、预热、HEIC 编码等优化策略
- Android 侧支持 `fastMode`、关键帧优先、并发切片、像素下压和 I/O 优化

## 功能特性

- 跨平台一致：Android 和 iOS 双端实现，Dart 层调用方式统一
- 高性能抽帧：适合生成视频封面墙、视频预览图、列表缩略图
- 尺寸可控：支持 `targetWidth`、`targetHeight`、`maxDecodePixels`
- 输出灵活：支持返回文件路径或内存字节
- 实用能力完整：支持取消任务、清理缓存、读取视频信息、提取单张封面

## 支持平台

- Android `minSdk = 21`
- iOS `12.0+`

## 安装

在你的 Flutter 项目中添加依赖：

```yaml
dependencies:
  brighton_video_keyframe_extractor: ^0.0.2
```

然后执行：

```bash
flutter pub get
```

## 导入

```dart
import 'package:brighton_video_keyframe_extractor/brighton_video_keyframe_extractor.dart';
```

## 快速开始

下面是最常见的抽帧方式：

```dart
final frames = await VideoKeyframeExtractor.extractKeyFrames(
  path: '/path/to/video.mp4',
  options: const VKExtractOptions(
    count: 12,
    outputMode: VKOutputMode.files,
    maxDecodePixels: 200000,
    preferClosestSync: true,
  ),
);
```

如果你更关注速度，可以直接使用极速预设：

```dart
final frames = await VideoKeyframeExtractor.extractKeyFrames(
  path: '/path/to/video.mp4',
  options: VKExtractOptions.fast(
    count: 12,
    taskId: 'cover_job_001',
  ),
);
```

## 核心参数

`VKExtractOptions` 用于控制抽帧行为：

```dart
class VKExtractOptions {
  final int count;
  final int? targetWidth;
  final int? targetHeight;
  final int? maxDecodePixels;
  final VKOutputMode outputMode;
  final bool preferClosestSync;
  final int? pageStart;
  final int? pageSize;
  final String? taskId;
  final int? quality;
  final int? maxConcurrency;
  final bool? fastMode;
}
```

常用字段说明：

- `count`：抽帧数量，建议不超过 20
- `outputMode`：`bytes` 返回字节，`files` 返回文件路径
- `targetWidth` / `targetHeight`：指定输出尺寸
- `maxDecodePixels`：按像素上限等比压缩，适合加速
- `preferClosestSync`：Android 是否优先抓关键帧
- `quality`：Android JPEG 质量，越低通常越快
- `maxConcurrency`：Android 最大并发数
- `taskId`：用于取消任务或清理该次任务缓存

## API 说明

### 1. 抽取关键帧

```dart
static Future<List<dynamic>> extractKeyFrames({
  required String path,
  required VKExtractOptions options,
})
```

- 当 `outputMode = VKOutputMode.files` 时，返回 `List<String>`
- 当 `outputMode = VKOutputMode.bytes` 时，返回 `List<Uint8List>`

### 2. 获取视频信息

```dart
static Future<Map<String, dynamic>> getMediaInfo(String path)
```

返回内容通常包含：

- `width`
- `height`
- `rotation`
- `durationMs`
- `bitrate`
- `fps`
- `sizeBytes`
- `mimeType`

### 3. 获取封面字节

```dart
static Future<Uint8List> getVideoCoverBytes(
  String path, {
  int? timeUs,
  int? targetWidth,
  int? targetHeight,
  int jpegQuality = 80,
  bool applyRotation = true,
})
```

### 4. 获取封面文件

```dart
static Future<String> getVideoCoverFile(
  String path, {
  int? timeUs,
  int? targetWidth,
  int? targetHeight,
  int jpegQuality = 80,
  bool applyRotation = true,
})
```

### 5. 取消任务与清理缓存

```dart
static Future<void> cancel({required String taskId});
static Future<void> clearCache({required String taskId});
static Future<void> clearAllCaches();
```

## 使用示例

### 自定义尺寸、质量、并发

```dart
final frames = await VideoKeyframeExtractor.extractKeyFrames(
  path: '/path/to/video.mov',
  options: const VKExtractOptions(
    count: 8,
    outputMode: VKOutputMode.bytes,
    targetWidth: 720,
    targetHeight: 1280,
    maxDecodePixels: 180000,
    preferClosestSync: true,
    quality: 65,
    maxConcurrency: 3,
  ),
);
```

### 获取单张封面

```dart
final cover = await VideoKeyframeExtractor.getVideoCoverBytes(
  '/path/to/video.mp4',
  timeUs: 3 * 1000 * 1000,
  targetWidth: 720,
  jpegQuality: 80,
);
```

### 获取媒体信息

```dart
final info = await VideoKeyframeExtractor.getMediaInfo('/path/to/video.mp4');
print(info['durationMs']);
print(info['width']);
print(info['height']);
```

### 取消与清理

```dart
final taskId = 'job_${DateTime.now().millisecondsSinceEpoch}';

final future = VideoKeyframeExtractor.extractKeyFrames(
  path: '/path/to/video.mp4',
  options: VKExtractOptions.fast(count: 12, taskId: taskId),
);

await VideoKeyframeExtractor.cancel(taskId: taskId);
await VideoKeyframeExtractor.clearCache(taskId: taskId);
await VideoKeyframeExtractor.clearAllCaches();
```

## 示例工程

仓库内自带可运行示例，见 [example](./example)。

示例覆盖的能力包括：

- 选择本地视频
- 抽取关键帧并预览
- 获取封面图
- 获取媒体信息
- 验证缓存清理与任务取消

## 仓库信息

- GitHub: [yunzhiheyi/brighton_video_keyframe_extractor](https://github.com/yunzhiheyi/brighton_video_keyframe_extractor)

