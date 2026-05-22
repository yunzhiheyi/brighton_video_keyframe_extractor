import 'package:flutter/foundation.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'brighton_video_keyframe_extractor_method_channel.dart';
import 'brighton_video_keyframe_extractor.dart';

abstract class VideoKeyframeExtractorPlatform extends PlatformInterface {
  /// Constructs a VideoKeyframeExtractorPlatform.
  VideoKeyframeExtractorPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoKeyframeExtractorPlatform _instance =
      MethodChannelVideoKeyframeExtractor();

  /// The default instance of [VideoKeyframeExtractorPlatform] to use.
  ///
  /// Defaults to [MethodChannelVideoKeyframeExtractor].
  static VideoKeyframeExtractorPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VideoKeyframeExtractorPlatform] when
  /// they register themselves.
  static set instance(VideoKeyframeExtractorPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  // 业务方法
  Future<List<dynamic>> extractKeyFrames({
    required String path,
    required VKExtractOptions options,
  });

  Future<void> cancel({required String taskId});
  Future<void> clearCache({required String taskId});
  Future<void> clearAllCaches();

  // 获取资源信息
  Future<Map<String, dynamic>> getMediaInfo({required String path});

  // 获取封面（两种形态都给，便于强类型）
  Future<Uint8List> getVideoCoverBytes({
    required String path,
    int? timeUs,
    int? targetWidth,
    int? targetHeight,
    int jpegQuality = 80,
    bool applyRotation = true,
  });

  Future<String> getVideoCoverFile({
    required String path,
    int? timeUs,
    int? targetWidth,
    int? targetHeight,
    int jpegQuality = 80,
    bool applyRotation = true,
  });
}
