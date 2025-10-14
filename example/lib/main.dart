import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_keyframe_extractor/video_keyframe_extractor.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keyframe Extractor Demo',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _videoPath;
  List<dynamic> _frames =
      []; // files 模式: List<String>；bytes 模式: List<Uint8List>
  bool _busy = false;

  // 统计指标
  int _elapsedMs = 0; // 本次抽帧总耗时（毫秒）
  double _avgPerFrameMs = 0; // 平均每帧耗时（毫秒/帧）
  double _throughput = 0; // 吞吐量（帧/秒）

  // 注意：taskId 不能是 final，每次抽帧/选择新视频都要刷新，避免命中 ImageCache
  String _taskId = _newTaskId();

  final _countCtrl = TextEditingController(text: '12');
  final _wCtrl = TextEditingController(text: ''); // 可选：目标宽
  final _hCtrl = TextEditingController(text: ''); // 可选：目标高

  VKOutputMode _mode = VKOutputMode.files; // 推荐 files，省内存
  bool _preferClosestSync = false; // Android：更靠近 I 帧（稍慢）

  static String _newTaskId() => 'job_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _pickVideo() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.video, allowMultiple: false);
    if (res != null && res.files.single.path != null) {
      // 新视频 → 生成新的 taskId，避免缩略图路径复用
      final oldTask = _taskId;
      setState(() {
        _videoPath = res.files.single.path!;
        _taskId = _newTaskId();
        _frames = [];
        _elapsedMs = 0;
        _avgPerFrameMs = 0;
        _throughput = 0;
      });
      // 可选：清理上一次任务缓存（不必须）
      if (oldTask.isNotEmpty) {
        // 忽略异常
        VideoKeyframeExtractor.clearCache(taskId: oldTask).catchError((_) {});
      }
      // 双保险：清空 Flutter 图片缓存（上一批 file 路径可能还在 cache）
      _evictAllImageCaches();
    }
  }

  Future<void> _extract() async {
    if (_videoPath == null) return;

    final count = int.tryParse(_countCtrl.text.trim());
    final w = int.tryParse(_wCtrl.text.trim());
    final h = int.tryParse(_hCtrl.text.trim());
    if (count == null || count <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入正确的帧数（>0）')));
      return;
    }

    setState(() {
      _busy = true;
      _elapsedMs = 0;
      _avgPerFrameMs = 0;
      _throughput = 0;
      // 每次抽帧前也换一个 taskId，确保路径变化（即使没重新选视频）
      _taskId = _newTaskId();
    });

    final sw = Stopwatch()..start();
    try {
      final res = await VideoKeyframeExtractor.extractKeyFrames(
        path: _videoPath!,
        options: VKExtractOptions(
          count: count,
          targetWidth: w,
          targetHeight: h,
          maxDecodePixels: 200000,
          outputMode: _mode,
          pageStart: 0,
          pageSize: count,
          quality: 70,
          preferClosestSync: _preferClosestSync, // Android only
          fastMode: true, // Android only
          taskId: _taskId, // ✅ 保证每次调用路径不同
        ),
      );
      sw.stop();
      final elapsed = sw.elapsedMilliseconds;
      final frames = res.length;

      // 更新前清空图片缓存，避免旧像素被复用
      _evictAllImageCaches();

      setState(() {
        _frames = res;
        _elapsedMs = elapsed;
        _avgPerFrameMs = frames == 0 ? 0 : elapsed / frames;
        _throughput = elapsed == 0 ? 0 : (frames * 1000.0) / elapsed; // 帧/秒
      });
    } catch (e) {
      sw.stop();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('抽帧失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async =>
      VideoKeyframeExtractor.cancel(taskId: _taskId);

  Future<void> _clearCache() async {
    await VideoKeyframeExtractor.clearCache(taskId: _taskId);
    _evictAllImageCaches();
    if (mounted) setState(() => _frames = []);
  }

  // 主动清空 Flutter 的图片缓存（双保险）
  void _evictAllImageCaches() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  Widget _thumb(dynamic item) {
    if (_mode == VKOutputMode.files) {
      final path = item as String;
      // 给 Image 一个基于路径的 Key，避免旧 Widget 被不恰当复用
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        key: ValueKey(path),
      );
    } else {
      final bytes =
          (item is Uint8List) ? item : Uint8List.fromList(item as List<int>);
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        // bytes 模式一般不需要 key，但加上也无妨
        key: ValueKey(bytes.hashCode),
      );
    }
  }

  @override
  void dispose() {
    _countCtrl.dispose();
    _wCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canRun = _videoPath != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Video Keyframe Extractor')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _countCtrl,
                      decoration:
                          const InputDecoration(labelText: '关键帧个数（count）'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                ]),
                // 参数输入
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _wCtrl,
                      decoration: const InputDecoration(labelText: '目标宽（可选）'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: TextField(
                      controller: _hCtrl,
                      decoration: const InputDecoration(labelText: '目标高（可选）'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ]),
                const SizedBox(height: 20),

                // 模式与开关
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start, // ← 整行顶齐且向左
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, // ← 列内向左
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          const Text('输出模式'),
                          Align(
                            alignment: Alignment.centerLeft, // ← 控件靠左
                            child: DropdownButton<VKOutputMode>(
                              value: _mode,
                              alignment: AlignmentDirectional
                                  .centerStart, // Flutter 3.7+
                              // isExpanded: true, // 若希望按钮拉满宽度再左对齐，可打开
                              items: const [
                                DropdownMenuItem(
                                    value: VKOutputMode.files,
                                    child: Text('Files（推荐）')),
                                DropdownMenuItem(
                                    value: VKOutputMode.bytes,
                                    child: Text('Bytes')),
                              ],
                              onChanged: (v) => setState(
                                  () => _mode = v ?? VKOutputMode.files),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, // ← 列内向左
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          const Text('I帧优先(Android)'),
                          Align(
                            alignment: Alignment.centerLeft, // ← 开关靠左
                            child: Switch(
                              value: _preferClosestSync,
                              onChanged: (v) =>
                                  setState(() => _preferClosestSync = v),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                // 操作按钮
                Wrap(spacing: 6, children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _pickVideo,
                    icon: const Icon(Icons.video_file),
                    label: const Text('选择视频'),
                  ),
                  FilledButton.icon(
                    onPressed: canRun ? _extract : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('抽取帧'),
                  ),
                  // OutlinedButton.icon(
                  //   onPressed: _cancel,
                  //   icon: const Icon(Icons.stop_circle_outlined),
                  //   label: const Text('取消任务'),
                  // ),
                  OutlinedButton.icon(
                    onPressed: _clearCache,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('清理缓存'),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(_videoPath == null ? '未选择视频' : '已选择：$_videoPath'),

                const SizedBox(height: 12),
                // 性能指标展示
                Row(
                  children: [
                    Text('总耗时: ${_elapsedMs}ms'),
                    const SizedBox(width: 16),
                    Text('平均/帧: ${_avgPerFrameMs.toStringAsFixed(1)}ms'),
                    const SizedBox(width: 16),
                    Text('吞吐量: ${_throughput.toStringAsFixed(2)} 帧/秒'),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // 结果网格
          Expanded(
            child: _frames.isEmpty
                ? const Center(child: Text('无缩略图'))
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8),
                    itemCount: _frames.length,
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _thumb(_frames[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
