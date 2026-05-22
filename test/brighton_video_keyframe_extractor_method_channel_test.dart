import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:brighton_video_keyframe_extractor/brighton_video_keyframe_extractor_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelVideoKeyframeExtractor platform = MethodChannelVideoKeyframeExtractor();
  const MethodChannel channel = MethodChannel('brighton_video_keyframe_extractor');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
