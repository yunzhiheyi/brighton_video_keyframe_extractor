import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'video_keyframe_extractor_platform_interface.dart';
import 'video_keyframe_extractor.dart';

/// An implementation of [VideoKeyframeExtractorPlatform] that uses method channels.
class MethodChannelVideoKeyframeExtractor extends VideoKeyframeExtractorPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('video_keyframe_extractor');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

// 业务方法
  @override
  Future<List<dynamic>> extractKeyFrames({
    required String path,
    required VKExtractOptions options,
  }) async {
    final args = {'path': path, ...options.toMap()};
    final List<dynamic> res = await methodChannel.invokeMethod('extractKeyFrames', args);
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

}
