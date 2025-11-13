import Flutter
import UIKit
import AVFoundation
import CoreImage
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers

// ================== 轻量耗时埋点（中文日志） ==================
final class T {
  private static var marks: [String: CFAbsoluteTime] = [:]
  @discardableResult
  static func start(_ k: String) -> String { marks[k] = CFAbsoluteTimeGetCurrent(); return k }
  static func lap(_ k: String, _ msg: String = "") {
    if let t0 = marks[k] {
      let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
      print("VKFE ⏱️ \(k) +\(ms)ms \(msg)")
    }
  }
  static func end(_ k: String, _ msg: String = "") { lap(k, msg); marks.removeValue(forKey: k) }
}

struct VideoInfoResult {
  let width: Int
  let height: Int
  let rotation: Int
  let durationMs: Int

  /// 编码器估算码率（来自 track.estimatedDataRate，bps）
  let bitrate: Int
  /// 更精准 fps（优先 nominal，其次 minFrameDuration，再次 Reader 采样）
  let fps: Double
  let sizeBytes: Int
  let mimeType: String
}

// ================== 插件主体 ==================
public class VideoKeyframeExtractorPlugin: NSObject, FlutterPlugin {

  // 任务取消标记：taskId -> Bool
  private var cancelled: [String: Bool] = [:]
  private let cancelLock = NSLock()

  // 共享 CIContext（GPU 加速）
  private static let sharedCIContext: CIContext = {
    CIContext(options: [CIContextOption.useSoftwareRenderer: false])
  }()

  // MARK: - 注册
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "video_keyframe_extractor", binaryMessenger: registrar.messenger())
    let instance = VideoKeyframeExtractorPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  // MARK: - MethodChannel 分发
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)

    case "extractKeyFrames":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "ARG_ERROR", message: "参数缺失", details: nil)); return
      }
      handleExtract(args: args, result: result)

    case "cancel":
      if let args = call.arguments as? [String: Any], let taskId = args["taskId"] as? String {
        setCancelled(taskId: taskId, value: true)
        print("VKFE 📢 收到取消任务：taskId=\(taskId)")
      }
      result(nil)

    case "clearCache":
      if let args = call.arguments as? [String: Any], let taskId = args["taskId"] as? String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video_keyframes/\(taskId)")
        try? FileManager.default.removeItem(at: dir)
        print("VKFE 🧹 已清理任务缓存：\(dir.path)")
      }
      result(nil)

    case "getMediaInfo":
       guard
         let args = call.arguments as? [String: Any],
         let path = args["path"] as? String
         else {
             result(FlutterError(code: "ARG_ERROR", message: "path 不能为空", details: nil))
             return
         }

         DispatchQueue.global(qos: .userInitiated).async {
             do {
                 let map = try self.getMediaInfo(path: path)
                 DispatchQueue.main.async { result(map) }
             } catch {
                 DispatchQueue.main.async {
                     result(FlutterError(code: "MEDIA_INFO_ERROR",
                                         message: error.localizedDescription,
                                         details: nil))
                 }
             }
         }

    case "getVideoCover":
      guard let args = call.arguments as? [String: Any],
            var path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "ARG_ERROR", message: "path 不能为空", details: nil)); return
      }
      if !path.hasPrefix("file://") { path = "file://" + path }
      handleGetVideoCover(args: args, path: path, result: result)

    case "clearAllCaches":
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("video_keyframes")
      try? FileManager.default.removeItem(at: root)
      print("VKFE 🧹 已清理所有缓存：\(root.path)")
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 抽帧主流程（含“稀疏全片→并行Generator”自适应）
  private func handleExtract(args: [String: Any], result: @escaping FlutterResult) {
    T.start("total")

    // —— 必填 ——
    guard var path = args["path"] as? String,
          let count = args["count"] as? Int, count > 0 else {
      result(FlutterError(code: "ARG_ERROR", message: "参数错误：path 或 count 无效", details: nil))
      return
    }
    if !path.hasPrefix("file://") { path = "file://" + path }

    // —— 可选参数 ——
    let targetWidth  = args["targetWidth"] as? Int
    let targetHeight = args["targetHeight"] as? Int
    let maxDecodePixelsArg = args["maxDecodePixels"] as? Int
    let outputMode = (args["outputMode"] as? String) ?? "files" // "bytes" | "files"
    let pageStart = (args["pageStart"] as? Int) ?? 0
    let pageSize  = (args["pageSize"]  as? Int) ?? count
    let taskId = (args["taskId"] as? String) ?? "task_\(Int(Date().timeIntervalSince1970))"

    // —— Reader/并发/编码参数 ——
    let useReaderParam = args["useReader"] as? Bool              // 允许为 nil，nil 则自适应
    let useSegmentedReader = (args["useSegmentedReader"] as? Bool) ?? true
    let segmentGapMs = (args["segmentGapMs"] as? Int) ?? 3000
    let segmentMaxSpanSec = (args["segmentMaxSpanSec"] as? Double) ?? 15.0
    let matchWindowMs = (args["matchWindowMs"] as? Int) ?? 40
    let prerollMs = (args["prerollMs"] as? Int) ?? 150
    let interiorToleranceMs = (args["interiorToleranceMs"] as? Int) ?? 30
    let generatorConcurrencyArg = (args["generatorConcurrency"] as? Int)
    let formatArg = (args["format"] as? String)
    let jpegQInt = (args["jpegQuality"] as? Int) ?? ((args["quality"] as? Int) ?? 70)
    let jpegQualityDefault = CGFloat(max(40, min(100, jpegQInt))) / 100.0

    // 复位取消
    setCancelled(taskId: taskId, value: false)

    print("VKFE ▶️ 开始抽帧 | taskId=\(taskId) | count=\(count) | outputMode=\(outputMode)")
    print("VKFE ⚙️ 参数 | matchWindowMs=\(matchWindowMs) prerollMs=\(prerollMs) segmentGapMs=\(segmentGapMs) segmentMaxSpanSec=\(segmentMaxSpanSec) jpegQuality=\(jpegQInt) maxDecodePixels=\(maxDecodePixelsArg ?? -1) generatorConcurrency=\(generatorConcurrencyArg ?? -1) format=\(formatArg ?? "jpg")")

    let url = URL(string: path)!
    let asset = AVURLAsset(url: url)

    asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { [weak self] in
      guard let self = self else { return }

      var error: NSError?
      let status = asset.statusOfValue(forKey: "duration", error: &error)
      guard status == .loaded else {
        result(FlutterError(code: "LOAD_ERROR", message: error?.localizedDescription, details: nil))
        return
      }

      let duration = asset.duration
      let durationSec = CMTimeGetSeconds(duration)
      guard durationSec.isFinite, durationSec > 0 else {
        result(FlutterError(code: "DURATION_ERROR", message: "无效的视频时长", details: nil))
        return
      }

      let track = asset.tracks(withMediaType: .video).first

      // 端点 ε + 帧网格时间
      let epsilon = self.computeEpsilonFrameInterval(track: track)
      let timesAll = self.computeTimesOnFrameGrid(duration: duration, track: track, n: count, epsilon: epsilon)

      // 分页
      let from = max(0, pageStart)
      let to = min(timesAll.count, pageStart + pageSize)
      if from >= to { DispatchQueue.main.async { result([]) }; return }

      // 覆盖率/稀疏度评估
      let timesPage = Array(timesAll[from..<to])
      let spanSec = max(0.0, CMTimeGetSeconds(timesPage.last! - timesPage.first!))
      let coverage = (durationSec > 0) ? (spanSec / durationSec) : 0

      // —— 自适应：稀疏全片 → 并行 Generator ——
      let shouldUseReader = self.decideUseReader(explicitUseReader: useReaderParam,
                                                 coverage: coverage,
                                                 pageFrameCount: timesPage.count)

      print(String(format: "VKFE ⚖️ 路径选择：useReader=%@ | 覆盖率=%.2f%% | 当前页帧数=%d",
                   shouldUseReader ? "YES" : "NO", coverage * 100, timesPage.count))
      print(String(format: "VKFE ℹ️ 视频时长=%.2fs | 目标范围=%.2fs | 覆盖率=%.2f%% | 分页=[%d,%d)",
                   durationSec, spanSec, coverage*100, from, to))

      if shouldUseReader {
        if useSegmentedReader {
          self.extractWithSegmentedReader(
            asset: asset,
            track: track,
            times: timesPage,
            outputMode: outputMode,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            maxDecodePixels: maxDecodePixelsArg,
            baseIndex: from,
            matchWindowMs: matchWindowMs,
            prerollMs: prerollMs,
            segmentGapMs: segmentGapMs,
            segmentMaxSpanSec: segmentMaxSpanSec,
            jpegQuality: jpegQualityDefault,
            taskId: taskId,
            result: result
          )
        } else {
          self.extractWithReader(
            asset: asset,
            track: track,
            times: timesPage,
            outputMode: outputMode,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            maxDecodePixels: maxDecodePixelsArg,
            baseIndex: from,
            matchWindowMs: matchWindowMs,
            prerollMs: prerollMs,
            jpegQuality: jpegQualityDefault,
            taskId: taskId,
            result: result
          )
        }
      } else {
        // —— 并行 Generator（稀疏+全片） —— ultraFastMode 自动开启
        let ultraFastMode: Bool = (coverage >= 0.60 && timesPage.count <= 16)

        // 动态并行度（A15+ 可给到 4）
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let effGeneratorConcurrency = generatorConcurrencyArg ?? (ultraFastMode ? min(4, max(3, cores / 2)) : 2)

        // 参数下压
        let effInteriorToleranceMs  = (ultraFastMode ? 250 : interiorToleranceMs)
        let effFormat               = (formatArg ?? (ultraFastMode ? "heic" : "jpg"))
        let effMaxDecodePixels      = (maxDecodePixelsArg ?? (ultraFastMode ? 160_000 : 200_000))
        let effJpegQuality          = (ultraFastMode ? CGFloat(55) / 100.0 : jpegQualityDefault)

        print("VKFE 🚀 ultraFastMode=\(ultraFastMode) | genConc=\(effGeneratorConcurrency) | tol=\(effInteriorToleranceMs)ms | fmt=\(effFormat) | maxPix=\(effMaxDecodePixels) | q=\(Int(effJpegQuality*100))")

        self.extractWithGeneratorConcurrent(
          asset: asset,
          track: track,
          times: timesAll,                 // 保持首尾语义（用全量 times）
          outputMode: outputMode,
          targetWidth: targetWidth,
          targetHeight: targetHeight,
          maxDecodePixels: effMaxDecodePixels,
          from: from,
          to: to,
          interiorToleranceMs: effInteriorToleranceMs,
          jpegQuality: effJpegQuality,
          format: effFormat,
          generatorConcurrency: effGeneratorConcurrency,
          ultraFastMode: ultraFastMode,
          taskId: taskId,
          result: result
        )
      }
    }
  }

  // MARK: - 通用资源信息获取（图片 / 视频）
  private func getMediaInfo(path: String) throws -> [String: Any] {
      let url = coerceFileURL(from: path)

      let mime = bestEffortMimeType(for: url) ?? "application/octet-stream"

      // === 图片类型 ===
      if mime.hasPrefix("image/") {
          guard let data = try? Data(contentsOf: url),
                let img = UIImage(data: data) else {
              throw NSError(domain: "MediaInfo", code: -10,
                            userInfo: [NSLocalizedDescriptionKey: "无法读取图片"])
          }

          return [
              "width": Int(img.size.width),
              "height": Int(img.size.height),
              "sizeBytes": data.count,
              "mimeType": mime,
              "format": url.pathExtension.lowercased()
          ]
      }
      // === 视频类型 ===
      if mime.hasPrefix("video/") {
          let v = try handleGetVideoInfo(path: path)
          return [
              "width": v.width,
              "height": v.height,
              "rotation": v.rotation,
              "durationMs": v.durationMs,
              "bitrate": v.bitrate,
              "fps": v.fps,
              "sizeBytes": v.sizeBytes,
              "mimeType": v.mimeType
          ]
      }

      // === 其他资源类型 ===
      let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1

      return [
          "type": "unknown",
          "sizeBytes": fileSize,
          "mimeType": mime
      ]
  }


  // MARK: - 获取视频信息（优化版，保持同步接口，但内部已无同步阻塞等待）
  private func handleGetVideoInfo(path: String,
                                  fpsProbeSeconds: Double = 2.0,
                                  fpsProbeMaxFrames: Int = 200) throws -> VideoInfoResult {

      let url = coerceFileURL(from: path)
      let asset = AVURLAsset(url: url)
      let keys = ["duration", "tracks"]

      // 🔒 使用信号量来同步等待异步加载完成（替代 group.wait）
      var loadError: NSError?
      var loadStatus: AVKeyValueStatus = .failed
      var trackStatus: AVKeyValueStatus = .failed
      var loadedKeys: [String: AVKeyValueStatus] = [:]

      let semaphore = DispatchSemaphore(value: 0)

      // 在后台队列异步加载
      DispatchQueue.global(qos: .userInitiated).async {
          asset.loadValuesAsynchronously(forKeys: keys)

          // 检查每个 key 的加载状态
          for key in keys {
              let status = asset.statusOfValue(forKey: key, error: &loadError)
              loadedKeys[key] = status
              if status != .loaded {
                  DispatchQueue.main.async {
                      semaphore.signal() // 确保信号量最终被触发
                  }
                  return
              }
          }

          // 所有 key 都加载成功
          DispatchQueue.main.async {
              semaphore.signal()
          }
      }

      // 当前线程等待加载完成（替代 group.wait，但发生在后台加载之后）
      semaphore.wait()

      // 检查是否加载成功
      for key in keys {
          let status = asset.statusOfValue(forKey: key, error: &loadError)
          if status != .loaded {
              throw NSError(
                  domain: "VideoInfo",
                  code: -1,
                  userInfo: [NSLocalizedDescriptionKey: loadError?.localizedDescription ?? "加载 \(key) 失败"]
              )
          }
      }

      // 继续原有逻辑 —— 获取视频轨道等信息（全部同步执行，无阻塞）
      guard let track = asset.tracks(withMediaType: .video).first else {
          throw NSError(domain: "VideoInfo", code: -2, userInfo: [NSLocalizedDescriptionKey: "没有找到视频轨道"])
      }

      // 旋转角度
      let t = track.preferredTransform
      let rotation: Int = {
          if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return 90 }
          if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return 270 }
          if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return 180 }
          return 0
      }()

      let displayed = track.naturalSize.applying(t)
      let width = Int(abs(displayed.width.rounded()))
      let height = Int(abs(displayed.height.rounded()))

      let durationSec = CMTimeGetSeconds(asset.duration)
      let durationMs = Int((durationSec.isFinite ? durationSec : 0) * 1000)

      // 文件大小
      let sizeBytes: Int = {
          guard url.isFileURL else { return -1 }
          return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
      }()

      // 码率
      let overallBitrate = (durationSec > 0 && sizeBytes > 0) ? Int(Double(sizeBytes) * 8.0 / durationSec) : 0

      // FPS
      let fps: Double = {
          let n = Double(track.nominalFrameRate)
          if n > 0 { return n }
          if track.minFrameDuration.isValid, track.minFrameDuration.value > 0 {
              let fd = CMTimeGetSeconds(track.minFrameDuration)
              if fd > 0 { return 1.0 / fd }
          }
          guard fpsProbeSeconds > 0 else { return 0 }
          do {
              let reader = try AVAssetReader(asset: asset)
              let output = AVAssetReaderTrackOutput(
                  track: track,
                  outputSettings: [
                      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                  ]
              )
              output.alwaysCopiesSampleData = false
              if reader.canAdd(output) { reader.add(output) }
              let sampleWindow = min(durationSec, fpsProbeSeconds)
              reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: sampleWindow, preferredTimescale: 1000))
              guard reader.startReading() else { return 0 }
              var frames = 0
              while reader.status == .reading, frames < fpsProbeMaxFrames {
                  autoreleasepool {
                      if output.copyNextSampleBuffer() != nil { frames += 1 }
                  }
              }
              return sampleWindow > 0 ? Double(frames) / sampleWindow : 0
          } catch {
              return 0
          }
      }()

      let mimeType = bestEffortMimeType(for: url) ?? "application/octet-stream"

      return VideoInfoResult(
          width: width,
          height: height,
          rotation: rotation,
          durationMs: durationMs,
          bitrate: overallBitrate,
          fps: fps,
          sizeBytes: sizeBytes,
          mimeType: mimeType
      )
  }

  // MARK: - MIME 推断（UTType → 扩展名 → 头部嗅探 → 兜底）
   private func bestEffortMimeType(for url: URL) -> String? {

     // ---------- 1) 本地 URL：先試 typeIdentifier ----------
     if url.isFileURL,
        let values = try? url.resourceValues(forKeys: [.typeIdentifierKey]),
        let typeId = values.typeIdentifier {

       if #available(iOS 14.0, *) {
         if let ut = UTType(typeId),
            let mt = ut.preferredMIMEType,
            (mt.hasPrefix("image/") || mt.hasPrefix("video/")) {
           return mt
         }
       } else {
         if let mt = UTTypeCopyPreferredTagWithClass(typeId as CFString, kUTTagClassMIMEType)?
           .takeRetainedValue() as String?,
            (mt.hasPrefix("image/") || mt.hasPrefix("video/")) {
           return mt
         }
       }
     }

     // ---------- 2) UTType / 副檔名 ----------
     let ext = url.pathExtension.lowercased()
     if !ext.isEmpty {
       // 2-1) 用 UTType 解析副檔名
       if #available(iOS 14.0, *) {
         if let ut = UTType(filenameExtension: ext),
            let mt = ut.preferredMIMEType,
            (mt.hasPrefix("image/") || mt.hasPrefix("video/")) {
           return mt
         }
       } else {
         let extCF = ext as CFString
         if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, extCF, nil)?
           .takeRetainedValue(),
            let mt = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?
           .takeRetainedValue() as String?,
            (mt.hasPrefix("image/") || mt.hasPrefix("video/")) {
           return mt
         }
       }

       // 2-2) 副檔名 fallback：手工處理常見圖片 / 視頻
       // --- 圖片 ---
       switch ext {
         case "png":           return "image/png"
         case "jpg", "jpeg":   return "image/jpeg"
         case "gif":           return "image/gif"
         case "webp":          return "image/webp"
         case "bmp":           return "image/bmp"
         case "heic":          return "image/heic"
         case "heif":          return "image/heif"
         case "tif", "tiff":   return "image/tiff"
         case "ico":           return "image/x-icon"
         default: break
       }

       // --- 視頻 ---
       switch ext {
         case "mp4", "m4v":       return "video/mp4"
         case "mov":              return "video/quicktime"
         case "mkv":              return "video/x-matroska"
         case "webm":             return "video/webm"
         case "avi":              return "video/x-msvideo"
         case "wmv":              return "video/x-ms-wmv"
         case "3gp":              return "video/3gpp"
         case "3g2":              return "video/3gpp2"
         case "flv":              return "video/x-flv"
         case "f4v":              return "video/x-f4v"
         case "mpeg", "mpg":      return "video/mpeg"
         case "ts", "mts", "m2ts":return "video/MP2T"
         case "vob":              return "video/x-ms-vob"
         case "ogv":              return "video/ogg"
         case "rm":               return "application/vnd.rn-realmedia"
         case "rmvb":             return "application/vnd.rn-realmedia-vbr"
         case "asf":              return "video/x-ms-asf"
         case "mxf":              return "application/mxf"
         case "divx":             return "video/divx"
         case "xvid":             return "video/x-xvid"
         default: break
       }
     }

     // ---------- 3) Magic Number 嗅探（只判斷圖片 / 視頻） ----------
     if url.isFileURL,
        let fh = try? FileHandle(forReadingFrom: url) {
       let header = fh.readData(ofLength: 512)
       fh.closeFile()

       if let mt = mimeTypeFromMagicBytes(header) {
         return mt
       }
     }

     // ---------- 4) 兜底 ----------
     return "application/octet-stream"
   }

  // MARK: - Magic Number 判斷（只圖片 + 視頻）
  private func mimeTypeFromMagicBytes(_ header: Data) -> String? {
    if header.isEmpty { return nil }
    let bytes = [UInt8](header)
    let count = bytes.count

    // --- 圖片 ---

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if count >= 8,
       bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
       bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
      return "image/png"
    }

    // JPEG: FF D8 FF
    if count >= 3,
       bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
      return "image/jpeg"
    }

    // GIF: "GIF87a" / "GIF89a"
    if count >= 6,
       bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38,
       (bytes[4] == 0x37 || bytes[4] == 0x39), bytes[5] == 0x61 {
      return "image/gif"
    }

    // BMP: "BM"
    if count >= 2,
       bytes[0] == 0x42, bytes[1] == 0x4D {
      return "image/bmp"
    }

    // TIFF: "II*\0" or "MM\0*"
    if count >= 4 {
      if bytes[0] == 0x49, bytes[1] == 0x49, bytes[2] == 0x2A, bytes[3] == 0x00 {
        return "image/tiff"
      }
      if bytes[0] == 0x4D, bytes[1] == 0x4D, bytes[2] == 0x00, bytes[3] == 0x2A {
        return "image/tiff"
      }
    }

    // WebP: "RIFF" .... "WEBP"
    if count >= 12,
       bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
       bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
      return "image/webp"
    }

    // HEIF/HEIC：ISO BMFF + ftyp heic / heix / hevc / hevx / mif1 / msf1
    if count >= 12,
       bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
      let brand = String(bytes: bytes[8...11], encoding: .ascii)?.lowercased() ?? ""
      if ["heic", "heix", "hevc", "hevx"].contains(brand) {
        return "image/heic"
      }
      if ["mif1", "msf1"].contains(brand) {
        return "image/heif"
      }
    }

    // --- 視頻 ---

    if count >= 12 {
      // MP4 / MOV / 3GP：.... ftyp
      if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
        let brand = String(bytes: bytes[8...11], encoding: .ascii)?.lowercased() ?? ""
        if brand == "qt  " { return "video/quicktime" }
        if brand.hasPrefix("3gp") { return "video/3gpp" }
        return "video/mp4"
      }
    }

    // Matroska / WebM：EBML
    if header.starts(with: Data([0x1A, 0x45, 0xDF, 0xA3])) {
      if let s = String(data: header, encoding: .isoLatin1)?.lowercased(),
         s.contains("webm") {
        return "video/webm"
      }
      return "video/x-matroska"
    }

    // AVI：RIFF....AVI
    if count >= 12,
       bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
      let fourCC = header.subdata(in: 8..<12)
      if fourCC == Data([0x41, 0x56, 0x49, 0x20]) {
        return "video/x-msvideo"
      }
    }

    // FLV: "FLV"
    if count >= 3,
       bytes[0] == 0x46, bytes[1] == 0x4C, bytes[2] == 0x56 {
      return "video/x-flv"
    }

    // MPEG PS: 00 00 01 BA
    if count >= 4,
       bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01, bytes[3] == 0xBA {
      return "video/mpeg"
    }

    // TS: 第一 byte 是 sync（粗略兜底）
    if count >= 1, bytes[0] == 0x47 {
      return "video/MP2T"
    }

    // ASF/WMV: 30 26 B2 75 8E 66 CF 11 A6 D9 00 AA 00 62 CE 6C
    if count >= 16 {
      let asfSig: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                             0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]
      if Array(bytes[0..<16]) == asfSig {
        return "video/x-ms-asf"
      }
    }

    // RealMedia / RMVB: ".RMF"
    if count >= 4,
       bytes[0] == 0x2E, bytes[1] == 0x52, bytes[2] == 0x4D, bytes[3] == 0x46 {
      return "application/vnd.rn-realmedia"
    }

    // OGG / OGV: "OggS"
    if count >= 4,
       bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
      return "video/ogg"
    }

    return nil
  }


  // MARK: - 小工具
  private func coerceFileURL(from path: String) -> URL {
    if path.hasPrefix("file://"), let u = URL(string: path) { return u }
    return URL(fileURLWithPath: path)
  }

  // 工具：从 CGAffineTransform 推导 0/90/180/270°
  private static func rotationDegrees(from t: CGAffineTransform) -> Int {
    if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return 90 }
    if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return 270 }
    if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return 180 }
    return 0
  }

  // 工具：获取文件大小（file:// 才能拿到；其余返回 -1）
  private static func fileSizeBytes(for url: URL) -> Int {
    guard url.isFileURL else { return -1 }
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      return values.fileSize ?? -1
    } catch { return -1 }
  }

 // MARK: - 获取封面（默认第一帧）
 private func handleGetVideoCover(args: [String: Any], path: String, result: @escaping FlutterResult) {
   let url = URL(string: path)!
   let asset = AVURLAsset(url: url)

   let timeUsArg = args["timeUs"] as? Int
   let targetW   = args["targetWidth"] as? Int
   let targetH   = args["targetHeight"] as? Int
   let jpegQInt  = (args["jpegQuality"] as? Int) ?? 80
   let returnMode = (args["returnMode"] as? String) ?? "bytes" // "bytes" | "file"

   let jpegQ = CGFloat(max(40, min(100, jpegQInt))) / 100.0

   asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
     var error: NSError?
     let status = asset.statusOfValue(forKey: "duration", error: &error)
     guard status == .loaded else {
       result(FlutterError(code: "LOAD_ERROR", message: error?.localizedDescription, details: nil))
       return
     }

     // 1) 计算时间点：未传入时默认第一帧（设为 0 或极小正数以避开个别容差问题）
     let tUsPrimary: Int64 = {
       if let u = timeUsArg, u > 0 { return Int64(u) }
       return 0 // ← 直接 0 代表第一帧
     }()
     let tUsFallback: Int64 = 100_000 // 100ms 兜底（极少数容器 0 帧取图会失败）

     // 2) 创建生成器
     let gen = AVAssetImageGenerator(asset: asset)
     gen.appliesPreferredTrackTransform = true
     gen.apertureMode = .encodedPixels
     // 为了尽量拿到“第一帧”，把容差设为 0
     gen.requestedTimeToleranceBefore = .zero
     gen.requestedTimeToleranceAfter  = .zero

     // 计算最大输出尺寸（与你原逻辑一致）
     if let w = targetW, let h = targetH {
       gen.maximumSize = CGSize(width: w, height: h)
     } else if let tr = asset.tracks(withMediaType: .video).first {
       let s = tr.naturalSize.applying(tr.preferredTransform)
       let sw = abs(s.width), sh = abs(s.height)
       if sw > 0, sh > 0 {
         _ = (sw, sh) // 如需限制最大分辨率，可在此处开启 maximumSize
       }
     }

     func emitWithCGImage(_ cg: CGImage) {
       if returnMode == "bytes" {
         if let data = self.fastJPEGData(fromCG: cg, quality: jpegQ) {
           result(FlutterStandardTypedData(bytes: data))
         } else {
           result(FlutterError(code: "COVER_ERROR", message: "JPEG 编码失败", details: nil))
         }
       } else {
         let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video_covers", isDirectory: true)
         try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
         let out = dir.appendingPathComponent("cover_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
         if let data = self.fastJPEGData(fromCG: cg, quality: jpegQ) {
           do {
             try data.write(to: out, options: [])
             result(out.path)
           } catch {
             result(FlutterError(code: "COVER_IO", message: "写入封面失败：\(error.localizedDescription)", details: nil))
           }
         } else {
           result(FlutterError(code: "COVER_ERROR", message: "JPEG 编码失败", details: nil))
         }
       }
     }

     // 3) 先试 0（或调用方传入的 timeUs），失败再试 100ms
     do {
       var actual = CMTime.zero
       let cg = try gen.copyCGImage(at: CMTime(value: tUsPrimary, timescale: 1_000_000), actualTime: &actual)
       emitWithCGImage(cg)
     } catch {
       // Fallback: 某些文件 0 点报错，向后平移到 100ms 再试
       do {
         var actual = CMTime.zero
         let cg = try gen.copyCGImage(at: CMTime(value: tUsFallback, timescale: 1_000_000), actualTime: &actual)
         emitWithCGImage(cg)
       } catch {
         result(FlutterError(code: "COVER_FAIL", message: error.localizedDescription, details: nil))
       }
     }
   }
 }

  // MARK: - 并行 AVAssetImageGenerator（稀疏场景更快，ultraFast 容差=∞ + 两帧预热 + 非原子写）
  private func extractWithGeneratorConcurrent(
    asset: AVAsset,
    track: AVAssetTrack?,
    times: [CMTime],
    outputMode: String,
    targetWidth: Int?,
    targetHeight: Int?,
    maxDecodePixels: Int?,
    from: Int,
    to: Int,
    interiorToleranceMs: Int,
    jpegQuality: CGFloat,
    format: String,                 // "jpg" | "heic"
    generatorConcurrency: Int,      // 建议 2~4
    ultraFastMode: Bool,            // 极限快照模式
    taskId: String,
    result: @escaping FlutterResult
  ) {
    let total = max(0, to - from)
    if total == 0 { DispatchQueue.main.async { result([]) }; return }

    // 计算输出尺寸
    var maximumSize: CGSize?
    if let w = targetWidth, let h = targetHeight {
      maximumSize = CGSize(width: w, height: h)
    } else if let maxPixels = maxDecodePixels, let tr = track {
      let s = tr.naturalSize.applying(tr.preferredTransform)
      let sw = abs(s.width), sh = abs(s.height)
      if sw > 0, sh > 0 {
        let scale = sqrt(CGFloat(maxPixels) / max(1, sw * sh))
        if scale < 1 {
          maximumSize = CGSize(width: max(1, Int(sw * scale)), height: max(1, Int(sh * scale)))
        }
      }
    }

    // 输出目录
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("video_keyframes/\(taskId)", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    // 容差：ultraFast → 所有帧 = ∞；否则使用传入的 interiorToleranceMs
    let interiorTol: CMTime = ultraFastMode
      ? .positiveInfinity
      : CMTime(value: CMTimeValue(interiorToleranceMs), timescale: 1000)

    // 并发 worker 数
    let workers = max(1, min(4, generatorConcurrency))

    // 均分 [from, to)
    func splitRange(_ start: Int, _ end: Int, parts: Int) -> [Range<Int>] {
      let n = end - start
      if n <= 0 || parts <= 1 { return n <= 0 ? [] : [start..<end] }
      let base = n / parts
      let rem  = n % parts
      var res: [Range<Int>] = []
      var s = start
      for p in 0..<parts {
        let sz = base + (p < rem ? 1 : 0)
        if sz > 0 { res.append(s..<(s + sz)); s += sz }
      }
      return res
    }
    let ranges = splitRange(from, to, parts: workers)
    print("VKFE ▶️ 并行 Generator | workers=\(workers) | ranges=\(ranges) | 输出目录=\(cacheDir.lastPathComponent) | tol=\(ultraFastMode ? "inf" : "\(interiorToleranceMs)ms")")

    var outputs: [Any?] = Array(repeating: nil, count: total)
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "vkfe.generator.concurrent", qos: .userInitiated, attributes: .concurrent)

    T.start("gen-par")

    for r in ranges {
      group.enter()
      queue.async {
        // 每个 worker 自己的 generator（线程不安全，必须各自实例）
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.apertureMode = .encodedPixels
        if let s = maximumSize { gen.maximumSize = s }

        // ★ 预热：两帧
        do {
          var _a = CMTime.zero
          _ = try? gen.copyCGImage(at: times[r.lowerBound], actualTime: &_a)
          if r.count >= 2 {
            _ = try? gen.copyCGImage(at: times[r.lowerBound + 1], actualTime: &_a)
          }
        }

        for i in r {
          if self.isCancelled(taskId: taskId) { break }
          autoreleasepool {
            if ultraFastMode {
              // 所有帧容差 = ∞（含首尾）
              gen.requestedTimeToleranceBefore = .positiveInfinity
              gen.requestedTimeToleranceAfter  = .positiveInfinity
            } else {
              if i == 0 || i == (times.count - 1) {
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter  = .zero
              } else {
                gen.requestedTimeToleranceBefore = interiorTol
                gen.requestedTimeToleranceAfter  = interiorTol
              }
            }

            do {
              var actual = CMTime.zero
              let cg = try gen.copyCGImage(at: times[i], actualTime: &actual)
              if outputMode == "bytes" {
                if let data = self.encodeImage(cg, quality: jpegQuality, format: format) {
                  outputs[i - from] = FlutterStandardTypedData(bytes: data)
                }
              } else {
                let filename = "\(i)." + (format.lowercased() == "heic" ? "heic" : "jpg")
                let outURL = cacheDir.appendingPathComponent(filename)
                if let data = self.encodeImage(cg, quality: jpegQuality, format: format) {
                  // 非原子写，降低文件系统额外开销
                  try? data.write(to: outURL, options: [])
                  outputs[i - from] = outURL.path
                }
              }
            } catch {
              print("VKFE ⚠️ 并行 Generator 抽帧失败：index=\(i) err=\(error.localizedDescription)")
            }
          }
        }
        group.leave()
      }
    }

    group.notify(queue: .main) {
      T.end("gen-par", "并行 Generator 完成")
      let list = outputs.compactMap { $0 }
      result(list)
    }
  }

  // MARK: - 分片 Reader（集中时段更快）
  private func extractWithSegmentedReader(
    asset: AVAsset,
    track: AVAssetTrack?,
    times: [CMTime],
    outputMode: String,
    targetWidth: Int?,
    targetHeight: Int?,
    maxDecodePixels: Int?,
    baseIndex: Int,
    matchWindowMs: Int,
    prerollMs: Int,
    segmentGapMs: Int,
    segmentMaxSpanSec: Double,
    jpegQuality: CGFloat,
    taskId: String,
    result: @escaping FlutterResult
  ) {
    guard let videoTrack = track else {
      result(FlutterError(code: "TRACK_ERROR", message: "未找到视频轨道", details: nil)); return
    }

    // 分片
    let segments = buildSegments(times: times, baseIndex: baseIndex, gapMs: segmentGapMs, maxSpanSec: segmentMaxSpanSec)
    print("VKFE 🔪 分片统计：片段数=\(segments.count)（gap>\(segmentGapMs)ms 或 单片跨度>\(segmentMaxSpanSec)s 会切段）")

    // 渲染尺寸
    let renderSize: CGSize? = {
      if let w = targetWidth, let h = targetHeight { return CGSize(width: w, height: h) }
      if let maxPixels = maxDecodePixels {
        let s = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let sw = abs(s.width), sh = abs(s.height)
        if sw > 0, sh > 0 {
          let scale = sqrt(CGFloat(maxPixels) / max(1, sw*sh))
          if scale < 1 {
            return CGSize(width: max(1, Int(sw * scale)), height: max(1, Int(sh * scale)))
          }
        }
      }
      return nil
    }()

    // 输出目录
    let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("video_keyframes/\(taskId)", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    let ctx = VideoKeyframeExtractorPlugin.sharedCIContext
    var outputs: [Any] = []
    let window = CMTime(value: CMTimeValue(matchWindowMs), timescale: 1000)
    let preroll = CMTime(value: CMTimeValue(prerollMs), timescale: 1000)

    // 逐段 Reader（串行更稳）
    var segIdx = 0
    for seg in segments {
      if isCancelled(taskId: taskId) { break }

      let firstT = seg.times.first!
      let lastT  = seg.times.last!
      var startT = CMTimeSubtract(firstT, preroll)
      if startT < .zero { startT = .zero }
      let endT = CMTimeAdd(lastT, window)
      let timeRange = CMTimeRangeFromTimeToTime(start: startT, end: endT)

      print(String(format: "VKFE 📦 片段#%d | 全局索引[%d..%d] | 目标帧数=%d | timeRange=%.3f~%.3fs (跨度≈%.3fs)",
                   segIdx, seg.baseIndex, seg.baseIndex + seg.times.count - 1, seg.times.count,
                   CMTimeGetSeconds(startT), CMTimeGetSeconds(endT), CMTimeGetSeconds(endT - startT)))

      T.start("seg-\(segIdx)")

      // Reader 设置
      let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
      ]
      let reader: AVAssetReader
      do { reader = try AVAssetReader(asset: asset) }
      catch { print("VKFE ❌ 创建 Reader 失败：\(error.localizedDescription)"); segIdx += 1; continue }

      let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
      trackOutput.alwaysCopiesSampleData = false
      if reader.canAdd(trackOutput) { reader.add(trackOutput) }
      reader.timeRange = timeRange

      guard reader.startReading() else {
        print("VKFE ❌ Reader 启动失败：\(reader.error?.localizedDescription ?? "unknown")")
        segIdx += 1; continue
      }

      // 逐帧读取
      var localIndex = 0
      while reader.status == .reading {
        if isCancelled(taskId: taskId) { reader.cancelReading(); break }
        guard let sample = trackOutput.copyNextSampleBuffer() else { break }

        autoreleasepool {
          let pts = CMSampleBufferGetPresentationTimeStamp(sample)
          while localIndex < seg.times.count {
            let targetT = seg.times[localIndex]
            if isPTS(pts, closeTo: targetT, window: window) || pts >= targetT {
              if let pixel = CMSampleBufferGetImageBuffer(sample) {
                let ci = CIImage(cvPixelBuffer: pixel)
                let outSize = renderSize ?? ci.extent.size
                let scaled = ci.transformed(by: scaleTransform(from: ci.extent.size, to: outSize))
                if let cg = ctx.createCGImage(scaled, from: CGRect(origin: .zero, size: outSize)),
                   let data = fastJPEGData(fromCG: cg, quality: jpegQuality) {
                  if outputMode == "bytes" {
                    outputs.append(FlutterStandardTypedData(bytes: data))
                  } else {
                    let outURL = cacheDir.appendingPathComponent("\(seg.baseIndex + localIndex).jpg")
                    try? data.write(to: outURL, options: [])
                    outputs.append(outURL.path)
                  }
                }
              }
              localIndex += 1
            } else { break }
          }
          if localIndex >= seg.times.count { reader.cancelReading() }
        }
      }

      T.end("seg-\(segIdx)", "片段#\(segIdx) 完成，读状态=\(reader.status.rawValue)")
      segIdx += 1
    }

    T.end("total", "全部完成（分片 Reader）")
    DispatchQueue.main.async { result(outputs) }
  }

  // MARK: - 单段 Reader（保留以兼容）
  private func extractWithReader(
    asset: AVAsset,
    track: AVAssetTrack?,
    times: [CMTime],
    outputMode: String,
    targetWidth: Int?,
    targetHeight: Int?,
    maxDecodePixels: Int?,
    baseIndex: Int,
    matchWindowMs: Int,
    prerollMs: Int,
    jpegQuality: CGFloat,
    taskId: String,
    result: @escaping FlutterResult
  ) {
    guard let videoTrack = track else {
      result(FlutterError(code: "TRACK_ERROR", message: "未找到视频轨道", details: nil)); return
    }

    let renderSize: CGSize? = {
      if let w = targetWidth, let h = targetHeight { return CGSize(width: w, height: h) }
      if let maxPixels = maxDecodePixels {
        let s = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let sw = abs(s.width), sh = abs(s.height)
        if sw > 0, sh > 0 {
          let scale = sqrt(CGFloat(maxPixels) / max(1, sw*sh))
          if scale < 1 {
            return CGSize(width: max(1, Int(sw * scale)), height: max(1, Int(sh * scale)))
          }
        }
      }
      return nil
    }()

    let firstT = times.first!
    let lastT  = times.last!
    let window = CMTime(value: CMTimeValue(matchWindowMs), timescale: 1000)
    let preroll = CMTime(value: CMTimeValue(prerollMs), timescale: 1000)
    var startT = CMTimeSubtract(firstT, preroll)
    if startT < .zero { startT = .zero }
    let endT = CMTimeAdd(lastT, window)
    let timeRange = CMTimeRangeFromTimeToTime(start: startT, end: endT)

    print(String(format: "VKFE ▶️ 单段 Reader | timeRange=%.3f~%.3fs | 目标帧数=%d",
                 CMTimeGetSeconds(startT), CMTimeGetSeconds(endT), times.count))

    let outputSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) }
    catch {
      result(FlutterError(code: "READER_ERROR", message: "创建 Reader 失败：\(error.localizedDescription)", details: nil)); return
    }
    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    trackOutput.alwaysCopiesSampleData = false
    if reader.canAdd(trackOutput) { reader.add(trackOutput) }
    reader.timeRange = timeRange

    guard reader.startReading() else {
      result(FlutterError(code: "READER_START_ERROR", message: reader.error?.localizedDescription, details: nil)); return
    }

    // 目录
    let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("video_keyframes/\(taskId)", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    let ctx = VideoKeyframeExtractorPlugin.sharedCIContext
    var outputs: [Any] = []
    var nextIndex = 0

    T.start("reader-once")
    while reader.status == .reading {
      if isCancelled(taskId: taskId) { reader.cancelReading(); break }
      guard let sample = trackOutput.copyNextSampleBuffer() else { break }
      autoreleasepool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        while nextIndex < times.count {
          let t = times[nextIndex]
          if isPTS(pts, closeTo: t, window: window) || pts >= t {
            if let pixel = CMSampleBufferGetImageBuffer(sample) {
              let ci = CIImage(cvPixelBuffer: pixel)
              let outSize = renderSize ?? ci.extent.size
              let scaled = ci.transformed(by: scaleTransform(from: ci.extent.size, to: outSize))
              if let cg = ctx.createCGImage(scaled, from: CGRect(origin: .zero, size: outSize)),
                 let data = fastJPEGData(fromCG: cg, quality: jpegQuality) {
                if outputMode == "bytes" {
                  outputs.append(FlutterStandardTypedData(bytes: data))
                } else {
                  let outURL = cacheDir.appendingPathComponent("\(baseIndex + nextIndex).jpg")
                  try? data.write(to: outURL, options: [])
                  outputs.append(outURL.path)
                }
              }
            }
            nextIndex += 1
          } else { break }
        }
        if nextIndex >= times.count { reader.cancelReading() }
      }
    }
    T.end("reader-once", "单段 Reader 完成")

    DispatchQueue.main.async { result(outputs) }
  }

  // MARK: - Generator（单线程保留，备用/对比）
  private func extractWithGenerator(
    asset: AVAsset,
    track: AVAssetTrack?,
    times: [CMTime],
    outputMode: String,
    targetWidth: Int?,
    targetHeight: Int?,
    maxDecodePixels: Int?,
    from: Int,
    to: Int,
    interiorToleranceMs: Int,
    jpegQuality: CGFloat,
    taskId: String,
    result: @escaping FlutterResult
  ) {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.apertureMode = .encodedPixels

    if let w = targetWidth, let h = targetHeight {
      generator.maximumSize = CGSize(width: w, height: h)
    } else if let maxPixels = maxDecodePixels, let tr = track {
      let s = tr.naturalSize.applying(tr.preferredTransform)
      let sw = abs(s.width), sh = abs(s.height)
      let scale = sqrt(CGFloat(maxPixels) / max(1, sw*sh))
      if scale < 1 {
        generator.maximumSize = CGSize(width: max(1, Int(sw * scale)), height: max(1, Int(sh * scale)))
      }
    }

    let interiorTol = CMTime(value: CMTimeValue(interiorToleranceMs), timescale: 1000)
    let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("video_keyframes/\(taskId)", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    print("VKFE ▶️ Generator | 输出目录=\(cacheDir.lastPathComponent) | 范围=[\(from)..\(to-1)]")

    T.start("gen")
    DispatchQueue.global(qos: .userInitiated).async {
      var outputs: [Any] = []
      for i in from..<to {
        if self.isCancelled(taskId: taskId) { break }
        autoreleasepool {
          if i == 0 || i == times.count - 1 {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter  = .zero
          } else {
            generator.requestedTimeToleranceBefore = interiorTol
            generator.requestedTimeToleranceAfter  = interiorTol
          }

          do {
            var actual = CMTime.zero
            let cg = try generator.copyCGImage(at: times[i], actualTime: &actual)
            if outputMode == "bytes" {
              if let data = self.fastJPEGData(fromCG: cg, quality: jpegQuality) {
                outputs.append(FlutterStandardTypedData(bytes: data))
              }
            } else {
              let outURL = cacheDir.appendingPathComponent("\(i).jpg")
              if let data = self.fastJPEGData(fromCG: cg, quality: jpegQuality) {
                try? data.write(to: outURL, options: [])
                outputs.append(outURL.path)
              }
            }
          } catch {
            print("VKFE ⚠️ Generator 抽帧失败：index=\(i) err=\(error.localizedDescription)")
          }
        }
      }

      T.end("gen", "Generator 完成")
      DispatchQueue.main.async { result(outputs) }
    }
  }

  // MARK: - 工具：分片、编码、匹配、缩放、时间计算

  private struct SegmentSpec { let times: [CMTime]; let baseIndex: Int }

  /// 分片：按 gapMs 把 times 切成多段；再按 maxSpanSec 限制单片跨度（过长再细分）
  private func buildSegments(times: [CMTime], baseIndex: Int, gapMs: Int, maxSpanSec: Double) -> [SegmentSpec] {
    if times.isEmpty { return [] }
    let gap = CMTime(value: CMTimeValue(gapMs), timescale: 1000)
    let maxSpan = CMTime(seconds: max(0.5, maxSpanSec), preferredTimescale: 1000)

    var specs: [SegmentSpec] = []
    var curr: [CMTime] = [times[0]]
    var currStartIdx = 0

    func pushCurr() {
      guard !curr.isEmpty else { return }
      let span = CMTimeSubtract(curr.last!, curr.first!)
      if CMTimeCompare(span, maxSpan) > 0, curr.count > 2 {
        var sub: [CMTime] = [curr.first!]
        var subStartBase = currStartIdx
        for i in 1..<curr.count {
          let d = CMTimeSubtract(curr[i], sub.first!)
          if CMTimeCompare(d, maxSpan) > 0 {
            specs.append(SegmentSpec(times: sub, baseIndex: baseIndex + subStartBase))
            sub = [curr[i]]
            subStartBase = currStartIdx + i
          } else {
            sub.append(curr[i])
          }
        }
        if !sub.isEmpty {
          specs.append(SegmentSpec(times: sub, baseIndex: baseIndex + subStartBase))
        }
      } else {
        specs.append(SegmentSpec(times: curr, baseIndex: baseIndex + currStartIdx))
      }
    }

    for i in 1..<times.count {
      let diff = CMTimeSubtract(times[i], times[i - 1])
      if CMTimeCompare(diff, gap) > 0 {
        pushCurr()
        curr = [times[i]]
        currStartIdx = i
      } else {
        curr.append(times[i])
      }
    }
    pushCurr()
    return specs
  }

  /// 统一编码（JPG/HEIC），兼容新旧 SDK
  private func encodeImage(_ cgImage: CGImage, quality: CGFloat, format: String) -> Data? {
    let useHeic = (format.lowercased() == "heic")
    let uti: CFString = {
      if useHeic {
        if #available(iOS 14.0, *) {
          return UTType.heic.identifier as CFString
        } else {
          return "public.heic" as CFString
        }
      } else {
        if #available(iOS 14.0, *) {
          return UTType.jpeg.identifier as CFString
        } else {
          return kUTTypeJPEG
        }
      }
    }()

    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, uti, 1, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
  }

  /// JPEG 编码（固定 JPG）
  private func fastJPEGData(fromCG cgImage: CGImage, quality: CGFloat) -> Data? {
    let jpegUTI: CFString = {
      if #available(iOS 14.0, *) {
        return UTType.jpeg.identifier as CFString
      } else {
        return kUTTypeJPEG
      }
    }()
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, jpegUTI, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
  }

  /// 时间命中窗口
  @inline(__always)
  private func isPTS(_ pts: CMTime, closeTo t: CMTime, window: CMTime) -> Bool {
    let diff = CMTimeSubtract(pts, t)
    return CMTimeAbsoluteValue(diff) <= window
  }

  /// 等比缩放变换
  private func scaleTransform(from src: CGSize, to dst: CGSize) -> CGAffineTransform {
    guard src.width > 0, src.height > 0 else { return .identity }
    let sx = dst.width / src.width
    let sy = dst.height / src.height
    return CGAffineTransform(scaleX: sx, y: sy)
  }

  /// 钳制
  @inline(__always)
  private func clampCMTime(_ t: CMTime, min minT: CMTime, max maxT: CMTime) -> CMTime {
    if CMTimeCompare(t, minT) < 0 { return minT }
    if CMTimeCompare(t, maxT) > 0 { return maxT }
    return t
  }

  /// 端点 ε（小于一帧）
  private func computeEpsilonFrameInterval(track: AVAssetTrack?) -> CMTime {
    if let t = track {
      if t.minFrameDuration.isValid && t.minFrameDuration.value > 0 {
        let frameDur = t.minFrameDuration
        return CMTimeMultiplyByFloat64(frameDur, multiplier: 0.2)
      }
      let fps = t.nominalFrameRate
      if fps > 0 {
        let frameDur = CMTimeMake(value: 1, timescale: Int32(fps.rounded()))
        return CMTimeMultiplyByFloat64(frameDur, multiplier: 0.2)
      }
    }
    return CMTimeMake(value: 1, timescale: 1000)
  }

  /// 帧网格时间（首=0、末=D-ε），按帧索引线性映射
  private func computeTimesOnFrameGrid(duration: CMTime, track: AVAssetTrack?, n: Int, epsilon: CMTime) -> [CMTime] {
    if n <= 1 { return [CMTime.zero] }
    var frameDur: CMTime = CMTimeMake(value: 1, timescale: 1000)
    if let t = track {
      if t.minFrameDuration.isValid && t.minFrameDuration.value > 0 {
        frameDur = t.minFrameDuration
      } else if t.nominalFrameRate > 0 {
        frameDur = CMTimeMake(value: 1, timescale: Int32(t.nominalFrameRate.rounded()))
      }
    }
    let usable = CMTimeSubtract(duration, epsilon)
    let usableSec = CMTimeGetSeconds(usable)
    let frameDurSec = max(1e-6, CMTimeGetSeconds(frameDur))
    let frames = max(1, Int((usableSec / frameDurSec).rounded()))
    var ts: [CMTime] = []
    let scale = duration.timescale
    for i in 0..<n {
      let ratio = Double(i) / Double(n - 1)
      let idx = Int((ratio * Double(frames - 1)).rounded())
      var t = CMTimeMultiply(frameDur, multiplier: Int32(idx))
      t = clampCMTime(t, min: .zero, max: usable)
      ts.append(CMTime(seconds: CMTimeGetSeconds(t), preferredTimescale: scale))
    }
    ts[0] = .zero
    ts[n - 1] = usable
    return ts
  }

  // 取消
  private func isCancelled(taskId: String) -> Bool {
    cancelLock.lock(); defer { cancelLock.unlock() }
    return cancelled[taskId] ?? false
  }
  private func setCancelled(taskId: String, value: Bool) {
    cancelLock.lock(); cancelled[taskId] = value; cancelLock.unlock()
  }

  // —— 自适应：稀疏全片 → 并行 Generator ——
  @inline(__always)
  private func decideUseReader(explicitUseReader: Bool?, coverage: Double, pageFrameCount: Int) -> Bool {
    if let explicit = explicitUseReader { return explicit }
    if coverage >= 0.60 && pageFrameCount <= 16 {
      print("VKFE 🤖 自适应：判定为“稀疏全片”，切换到 Generator")
      return false
    }
    print("VKFE 🤖 自适应：判定为“集中/半集中”，采用 Reader")
    return true
  }
}
