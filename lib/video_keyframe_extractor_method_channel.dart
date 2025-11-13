import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'video_keyframe_extractor_platform_interface.dart';
import 'video_keyframe_extractor.dart';

/// An implementation of [VideoKeyframeExtractorPlatform] that uses method channels.
class MethodChannelVideoKeyframeExtractor
    extends VideoKeyframeExtractorPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('video_keyframe_extractor');

  @override
  Future<String?> getPlatformVersion() async {
    final version =
        await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

// 业务方法
  @override
  Future<List<dynamic>> extractKeyFrames({
    required String path,
    required VKExtractOptions options,
  }) async {
    final args = {'path': path, ...options.toMap()};
    final List<dynamic> res =
        await methodChannel.invokeMethod('extractKeyFrames', args);
    return res;
  }

  @override
  Future<void> cancel({required String taskId}) async {
    await methodChannel.invokeMethod('cancel', {'taskId': taskId});
  }

  @override
  Future<void> clearCache({required String taskId}) async {
    await methodChannel.invokeMethod('clearCache', {'taskId': taskId});
  }

  @override
  Future<void> clearAllCaches() async {
    await methodChannel.invokeMethod('clearAllCaches');
  }

  /// 视频信息
  @override
  Future<Map<String, dynamic>> getVideoInfo({required String path}) async {
    final map = await methodChannel
        .invokeMethod<dynamic>('getVideoInfo', {'path': path});
    return Map<String, dynamic>.from(map as Map);
  }

  /// 视频封面（bytes）
  @override
  Future<Uint8List> getVideoCoverBytes({
    required String path,
    int? timeUs,
    int? targetWidth,
    int? targetHeight,
    int jpegQuality = 80,
    bool applyRotation = true,
  }) async {
    final bytes = await methodChannel.invokeMethod<Uint8List>('getVideoCover', {
      'path': path,
      'timeUs': timeUs,
      'targetWidth': targetWidth,
      'targetHeight': targetHeight,
      'jpegQuality': jpegQuality,
      'returnMode': 'bytes',
      'applyRotation': applyRotation,
    });
    if (bytes == null) {
      throw PlatformException(
          code: 'COVER_ERROR', message: 'getVideoCover 返回空 bytes');
    }
    return bytes;
  }

  /// 视频封面（文件路径）
  @override
  Future<String> getVideoCoverFile({
    required String path,
    int? timeUs,
    int? targetWidth,
    int? targetHeight,
    int jpegQuality = 80,
    bool applyRotation = true,
  }) async {
    final p = await methodChannel.invokeMethod<String>('getVideoCover', {
      'path': path,
      'timeUs': timeUs,
      'targetWidth': targetWidth,
      'targetHeight': targetHeight,
      'jpegQuality': jpegQuality,
      'returnMode': 'file',
      'applyRotation': applyRotation,
    });
    if (p == null || p.isEmpty) {
      throw PlatformException(
          code: 'COVER_ERROR', message: 'getVideoCover 返回空路径');
    }
    return p;
  }
}
