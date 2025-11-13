import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_keyframe_extractor/video_keyframe_extractor.dart';
import 'package:video_keyframe_extractor/video_keyframe_extractor_method_channel.dart';
import 'package:video_keyframe_extractor/video_keyframe_extractor_platform_interface.dart';

/// 模拟平台层实现，用于单元测试
class MockVideoKeyframeExtractorPlatform
    with MockPlatformInterfaceMixin
    implements VideoKeyframeExtractorPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('mock_1.0.0');

  @override
  Future<List<dynamic>> extractKeyFrames({
    required String path,
    required VKExtractOptions options,
  }) async {
    // 模拟返回 N 个虚拟帧路径
    return List.generate(options.count, (i) => '/tmp/mock_frame_$i.jpg');
  }

  @override
  Future<void> cancel({required String taskId}) async {
    // 模拟取消，无操作
  }

  @override
  Future<void> clearCache({required String taskId}) async {
    // 模拟清理缓存，无操作
  }

  @override
  Future<void> clearAllCaches() async {
    // 模拟清理全部缓存，无操作
  }

  @override
  Future<Uint8List> getVideoCoverBytes(
      {required String path,
      int? timeUs,
      int? targetWidth,
      int? targetHeight,
      int jpegQuality = 80,
      bool applyRotation = true}) {
    // TODO: implement getVideoCoverBytes
    throw UnimplementedError();
  }

  @override
  Future<String> getVideoCoverFile(
      {required String path,
      int? timeUs,
      int? targetWidth,
      int? targetHeight,
      int jpegQuality = 80,
      bool applyRotation = true}) {
    // TODO: implement getVideoCoverFile
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> getMediaInfo({required String path}) {
    // TODO: implement getVideoInfo
    throw UnimplementedError();
  }
}

void main() {
  final VideoKeyframeExtractorPlatform initialPlatform =
      VideoKeyframeExtractorPlatform.instance;

  group('VideoKeyframeExtractorPlugin', () {
    test('默认实例应为 MethodChannelVideoKeyframeExtractor', () {
      expect(
          initialPlatform, isInstanceOf<MethodChannelVideoKeyframeExtractor>());
    });

    test('getPlatformVersion 应该返回 mock_1.0.0', () async {
      final plugin = VideoKeyframeExtractor();
      final fakePlatform = MockVideoKeyframeExtractorPlatform();
      VideoKeyframeExtractorPlatform.instance = fakePlatform;

      final version = await plugin.getPlatformVersion();
      expect(version, 'mock_1.0.0');
    });

    test('extractKeyFrames 应返回模拟帧路径', () async {
      final plugin = VideoKeyframeExtractor();
      final fakePlatform = MockVideoKeyframeExtractorPlatform();
      VideoKeyframeExtractorPlatform.instance = fakePlatform;

      final options = VKExtractOptions(count: 3);
      final frames = await VideoKeyframeExtractor.extractKeyFrames(
        path: '/tmp/mock_video.mp4',
        options: options,
      );

      expect(frames, hasLength(3));
      expect(frames.first, '/tmp/mock_frame_0.jpg');
    });

    test('cancel / clearCache / clearAllCaches 不应抛异常', () async {
      final fakePlatform = MockVideoKeyframeExtractorPlatform();
      VideoKeyframeExtractorPlatform.instance = fakePlatform;

      await expectLater(
        VideoKeyframeExtractor.cancel(taskId: 'job_1'),
        completes,
      );
      await expectLater(
        VideoKeyframeExtractor.clearCache(taskId: 'job_1'),
        completes,
      );
      await expectLater(
        VideoKeyframeExtractor.clearAllCaches(),
        completes,
      );
    });
  });
}
