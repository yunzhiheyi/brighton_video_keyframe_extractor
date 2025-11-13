import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const _channel = MethodChannel('video_keyframe_extractor');

  String? _videoPath;
  List<dynamic> _frames = []; // files 模式: List<String>；bytes 模式: List<Uint8List>
  bool _busy = false;

  // 统计指标（抽帧）
  int _elapsedMs = 0; // 本次抽帧总耗时（毫秒）
  double _avgPerFrameMs = 0; // 平均每帧耗时（毫秒/帧）
  double _throughput = 0; // 吞吐量（帧/秒）

  // 缩略图 & 视频信息（新加）
  Uint8List? _coverBytes; // 获取封面(bytes)
  Map<String, dynamic>? _videoInfo; // 获取视频信息

  // 注意：taskId 不能是 final，每次抽帧/选择新视频都要刷新，避免命中 ImageCache
  String _taskId = _newTaskId();

  final _countCtrl = TextEditingController(text: '12');
  final _wCtrl = TextEditingController(text: ''); // 可选：目标宽
  final _hCtrl = TextEditingController(text: ''); // 可选：目标高

  // 获取封面时刻（微秒），默认取中间帧；这里提供个输入框（可选）
  final _coverUsCtrl = TextEditingController(text: '');

  VKOutputMode _mode = VKOutputMode.files; // 推荐 files，省内存
  bool _preferClosestSync = false; // Android：更靠近 I 帧（稍慢）

  static String _newTaskId() => 'job_${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _pickVideo() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.video, allowMultiple: false);
    if (res != null && res.files.single.path != null) {
      final oldTask = _taskId;
      setState(() {
        _videoPath = res.files.single.path!;
        _taskId = _newTaskId();
        _frames = [];
        _elapsedMs = 0;
        _avgPerFrameMs = 0;
        _throughput = 0;
        _coverBytes = null;
        _videoInfo = null;
      });
      // 可选：清理上一次任务缓存（不必须）
      if (oldTask.isNotEmpty) {
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
      _taskId = _newTaskId(); // 每次调用都换
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
          taskId: _taskId, // ✅ 确保每次调用路径不同
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
    if (mounted) {
      setState(() {
        _frames = [];
        _coverBytes = null;
      });
    }
  }

  // ========== 新增：获取视频封面（bytes） ==========
  Future<void> _getCover() async {
    if (_videoPath == null) return;
    setState(() => _busy = true);

    try {
      final timeUs = int.tryParse(_coverUsCtrl.text.trim()); // 可选
      final w = int.tryParse(_wCtrl.text.trim());
      final h = int.tryParse(_hCtrl.text.trim());

      final args = <String, dynamic>{
        'path': _videoPath!,
        if (timeUs != null && timeUs > 0) 'timeUs': timeUs,
        if (w != null && w > 0) 'targetWidth': w,
        if (h != null && h > 0) 'targetHeight': h,
        'jpegQuality': 80,
        'returnMode': 'bytes', // 直接返回字节
      };

      final bytes = await _channel.invokeMethod<Uint8List>('getVideoCover', args);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('获取封面失败：返回为空')),
          );
        }
        return;
      }

      // 更新前清空图片缓存，避免旧像素被复用
      _evictAllImageCaches();

      if (mounted) {
        setState(() => _coverBytes = bytes);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取封面失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ========== 新增：获取视频信息 ==========
  Future<void> _getVideoInfo() async {
    if (_videoPath == null) return;
    setState(() => _busy = true);
    try {
      final info = await _channel.invokeMethod<Map>('getVideoInfo', {
        'path': _videoPath!,
      });

      if (mounted) {
        setState(() => _videoInfo = info?.map((k, v) => MapEntry(k.toString(), v)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取视频信息失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // 主动清空 Flutter 的图片缓存（双保险）
  void _evictAllImageCaches() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  Widget _thumb(dynamic item) {
    if (_mode == VKOutputMode.files) {
      final path = item as String;
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        key: ValueKey(path), // 基于路径的 Key，避免复用
      );
    } else {
      final bytes =
      (item is Uint8List) ? item : Uint8List.fromList(item as List<int>);
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        key: ValueKey(bytes.hashCode),
      );
    }
  }

  @override
  void dispose() {
    _countCtrl.dispose();
    _wCtrl.dispose();
    _hCtrl.dispose();
    _coverUsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canRun = _videoPath != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Video Keyframe Extractor')),
      body: SingleChildScrollView(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ====== 参数区 ======
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
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _coverUsCtrl,
                      decoration: const InputDecoration(
                        labelText: '封面时间点（微秒，可选，留空取中间）',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                ]),
                const SizedBox(height: 20),

                // ====== 模式与开关 ======
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('输出模式'),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: DropdownButton<VKOutputMode>(
                              value: _mode,
                              alignment: AlignmentDirectional.centerStart,
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
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('I帧优先(Android)'),
                          Align(
                            alignment: Alignment.centerLeft,
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

                // ====== 按钮区 ======
                Wrap(spacing: 6, runSpacing: 6, children: [
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
                  FilledButton.icon(
                    onPressed: canRun ? _getCover : null,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('获取封面'),
                  ),
                  FilledButton.icon(
                    onPressed: canRun ? _getVideoInfo : null,
                    icon: const Icon(Icons.info_outline),
                    label: const Text('获取视频信息'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _clearCache,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('清理缓存'),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(_videoPath == null ? '未选择视频' : '已选择：$_videoPath'),

                const SizedBox(height: 12),
                // ====== 性能指标（抽帧） ======
                Row(
                  children: [
                    Text('总耗时: ${_elapsedMs}ms'),
                    const SizedBox(width: 16),
                    Text('平均/帧: ${_avgPerFrameMs.toStringAsFixed(1)}ms'),
                    const SizedBox(width: 16),
                    Text('吞吐量: ${_throughput.toStringAsFixed(2)} 帧/秒'),
                  ],
                ),

                const SizedBox(height: 12),
                // ====== 封面预览（新加） ======
                if (_coverBytes != null) ...[
                  const Text('封面预览（bytes）：'),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      _coverBytes!,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: 200,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // ====== 视频信息展示（新加） ======
                if (_videoInfo != null) ...[
                  const Text('视频信息：'),
                  const SizedBox(height: 8),
                  _buildInfoTable(_videoInfo!),
                ],
              ],
            ),
          ),

          const Divider(height: 1),

          // ====== 抽帧结果网格（原逻辑保留） ======
          SizedBox(
            height: 400,
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
      )),
    );
  }
// 工具：字节 -> B/KB/MB/GB
  String humanBytesSI(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    final fixed = (i == 0) ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    return '$fixed ${units[i]}';
  }


// 工具：码率 -> bps/Kbps/Mbps/Gbps（注意是千进）
  String _humanBps(int bps) {
    const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
    double v = bps.toDouble();
    int i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return '${v.toStringAsFixed(2)} ${units[i]}';
  }

// 工具：毫秒 -> hh:mm:ss.mmm（尾部毫秒可按需保留/去掉）
  String _humanDurationMs(int ms, {int roundUpThresholdMs = 500}) {
    if (ms < 0) ms = 0;
    final remainderMs = ms % 1000;
    int totalSeconds = ms ~/ 1000;

    if (remainderMs >= roundUpThresholdMs) {
      totalSeconds += 1;
    }

    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    String two(int n) => n.toString().padLeft(2, '0');

    return hours > 0
        ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  Widget _buildInfoTable(Map<String, dynamic> info) {
    String fmt(dynamic v) => v is double ? v.toStringAsFixed(2) : '$v';

    // 取出原始值
    final sizeBytesRaw = info['sizeBytes'];
    final encoderBpsRaw = info['bitrate'];
    final durationMsRaw = info['durationMs'];

    final int? sizeBytes = (sizeBytesRaw is num) ? sizeBytesRaw.toInt() : null;
    final int? encoderBps = (encoderBpsRaw is num) ? encoderBpsRaw.toInt() : null;
    final int? durationMs = (durationMsRaw is num) ? durationMsRaw.toInt() : null;

    final rows = <TableRow>[
      _kvRow('width', fmt(info['width'])),
      _kvRow('height', fmt(info['height'])),
      _kvRow('rotation', fmt(info['rotation'])),

      // 时长：原毫秒 + 人类可读
      _kvRow(
        'duration',
        durationMs == null ? '${info['durationMs']}' :
        '${durationMs} ms  (${_humanDurationMs(durationMs)})',
      ),

      _kvRow(
        'bitrate',
        encoderBps == null ? '${info['bitrate']}' :
        '${encoderBps} bps  (${_humanBps(encoderBps)})',
      ),

      _kvRow('fps', fmt(info['fps'])),

      // 大小：原始字节 + 人类可读（比如 123.45 MB）
      _kvRow(
        'size',
        sizeBytes == null ? '${info['sizeBytes']}' :
        '${sizeBytes} B  (${humanBytesSI(sizeBytes)})',
      ),

      _kvRow('mimeType', fmt(info['mimeType'])),
    ];

    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: rows,
    );
  }


  TableRow _kvRow(String k, String v) => TableRow(children: [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 22),
      child: Text(v),
    ),
  ]);
}
