import 'dart:typed_data';
import 'video_keyframe_extractor_platform_interface.dart';

/// 输出模式：返回 bytes 还是文件路径。
enum VKOutputMode { bytes, files }

/// 抽帧参数（已对齐 Android 端 fast patch）
class VKExtractOptions {
  /// 抽帧数量（建议 ≤20）
  final int count;

  /// 目标宽高（不指定时按 maxDecodePixels 等比缩放）
  final int? targetWidth;
  final int? targetHeight;

  /// 解码像素上限（越小越快），如 200_000 ≈ 长边 400~500px
  final int? maxDecodePixels;

  /// 输出模式：bytes（更快，少 I/O）或 files
  final VKOutputMode outputMode;

  /// Android：是否优先抓关键帧（CLOSEST_SYNC）
  final bool preferClosestSync;

  /// 分页：起始下标与每页数量（默认让插件用 count 作为 pageSize）
  final int? pageStart;
  final int? pageSize;

  /// 任务 id（用于取消/清理）
  final String? taskId;

  /// Android：JPEG 质量（40..100，建议 ≤70 以提速）
  final int? quality;

  /// Android：最大并发（1..6，建议 ≤3 防止解码器竞争）
  final int? maxConcurrency;

  /// Android：极速模式（命中条件时自动套用快速预设）
  final bool? fastMode;

  const VKExtractOptions({
    required this.count,
    this.targetWidth,
    this.targetHeight,
    this.maxDecodePixels,
    this.outputMode = VKOutputMode.files,
    this.preferClosestSync = false,
    this.pageStart,
    this.pageSize,
    this.taskId,
    this.quality,
    this.maxConcurrency,
    this.fastMode,
  });

  /// 极速预设（推荐）：1 秒内出图为目标（≤20 张、bytes、关键帧、降像素）
  factory VKExtractOptions.fast({
    required int count,
    String? taskId,
    int quality = 70,
    int maxDecodePixels = 200000,
    int maxConcurrency = 3,
  }) {
    return VKExtractOptions(
      count: count.clamp(1, 20),
      outputMode: VKOutputMode.bytes,
      preferClosestSync: true,
      maxDecodePixels: maxDecodePixels,
      quality: quality,
      maxConcurrency: maxConcurrency,
      fastMode: true,
      pageStart: 0,
      // 让插件端用 pageSize=count；如需也可自己填：pageSize: count.clamp(1, 20),
      taskId: taskId,
    );
  }

  Map<String, dynamic> toMap() => {
    'count': count,
    'targetWidth': targetWidth,
    'targetHeight': targetHeight,
    'maxDecodePixels': maxDecodePixels,
    'outputMode': outputMode.name, // "bytes"/"files"
    'preferClosestSync': preferClosestSync, // Android only
    'pageStart': pageStart ?? 0,
    // 若未显式给 pageSize，则用 count（便于一次性取完）
    'pageSize': pageSize ?? count,
    'taskId': taskId,
    'quality': quality, // Android only
    'maxConcurrency': maxConcurrency, // Android only
    'fastMode': fastMode, // Android only
  }..removeWhere((k, v) => v == null);
}

class VideoInfo {
  final int width;
  final int height;
  final int rotation;
  final int durationMs;
  final int bitrate;     // bps
  final double fps;      // 可能为 0.0
  final int sizeBytes;   // 可能为 -1
  final String mimeType;

  const VideoInfo({
    required this.width,
    required this.height,
    required this.rotation,
    required this.durationMs,
    required this.bitrate,
    required this.fps,
    required this.sizeBytes,
    required this.mimeType,
  });

  factory VideoInfo.fromMap(Map<String, dynamic> m) => VideoInfo(
    width: (m['width'] ?? 0) as int,
    height: (m['height'] ?? 0) as int,
    rotation: (m['rotation'] ?? 0) as int,
    durationMs: (m['durationMs'] ?? 0) as int,
    bitrate: (m['bitrate'] ?? 0) as int,
    fps: (m['fps'] ?? 0.0).toDouble(),
    sizeBytes: (m['sizeBytes'] ?? -1) as int,
    mimeType: (m['mimeType'] ?? '') as String,
  );
}

class VideoKeyframeExtractor {
  /// 模板：获取平台版本
  Future<String?> getPlatformVersion() {
    return VideoKeyframeExtractorPlatform.instance.getPlatformVersion();
  }

  /// 抽帧：返回文件路径或字节数组（由 options.outputMode 决定）
  static Future<List<dynamic>> extractKeyFrames({
    required String path,
    required VKExtractOptions options,
  }) {
    return VideoKeyframeExtractorPlatform.instance
        .extractKeyFrames(path: path, options: options);
  }

  /// 取消任务
  static Future<void> cancel({required String taskId}) {
    return VideoKeyframeExtractorPlatform.instance.cancel(taskId: taskId);
  }

  /// 清理指定任务缓存
  static Future<void> clearCache({required String taskId}) {
    return VideoKeyframeExtractorPlatform.instance.clearCache(taskId: taskId);
  }

  /// 清理所有缓存
  static Future<void> clearAllCaches() {
    return VideoKeyframeExtractorPlatform.instance.clearAllCaches();
  }

  /// 视频信息
  static Future<Map<String, dynamic>> getMediaInfo(String path) async {
    return await VideoKeyframeExtractorPlatform.instance.getMediaInfo(path: path);
    // 如需兼容 iOS 后续实现，这里无需改动
  }

  /// 封面（bytes）
  static Future<Uint8List> getVideoCoverBytes(
      String path, {
        int? timeUs,
        int? targetWidth,
        int? targetHeight,
        int jpegQuality = 80,
        bool applyRotation = true,
      }) {
    return VideoKeyframeExtractorPlatform.instance.getVideoCoverBytes(
      path: path,
      timeUs: timeUs,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      jpegQuality: jpegQuality,
      applyRotation: applyRotation,
    );
  }

  /// 封面（文件路径）
  static Future<String> getVideoCoverFile(
      String path, {
        int? timeUs,
        int? targetWidth,
        int? targetHeight,
        int jpegQuality = 80,
        bool applyRotation = true,
      }) {
    return VideoKeyframeExtractorPlatform.instance.getVideoCoverFile(
      path: path,
      timeUs: timeUs,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      jpegQuality: jpegQuality,
      applyRotation: applyRotation,
    );
  }

}
