import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'video_keyframe_extractor_method_channel.dart';
import 'video_keyframe_extractor.dart';

abstract class VideoKeyframeExtractorPlatform extends PlatformInterface {
  /// Constructs a VideoKeyframeExtractorPlatform.
  VideoKeyframeExtractorPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoKeyframeExtractorPlatform _instance = MethodChannelVideoKeyframeExtractor();

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
}
