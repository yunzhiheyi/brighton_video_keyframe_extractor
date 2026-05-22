// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:brighton_video_keyframe_extractor_example/main.dart';

void main() {
  testWidgets('示例首页应展示关键入口控件', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Video Keyframe Extractor'), findsOneWidget);
    expect(find.text('选择资源'), findsOneWidget);
    expect(find.text('获取封面'), findsOneWidget);
    expect(find.text('未选择视频'), findsOneWidget);
  });
}
