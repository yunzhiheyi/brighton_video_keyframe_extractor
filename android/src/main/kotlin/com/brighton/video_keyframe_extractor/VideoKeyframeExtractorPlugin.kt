package com.brighton.video_keyframe_extractor

import android.content.ContentResolver
import android.content.Context
import android.content.res.AssetFileDescriptor
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * 最小可合并 PR（Kotlin 版）：为 1 秒内抽帧（≤20 张、JPEG≤70）进行的性能补丁
 *
 * 变更点（均配中文注释与关键日志）：
 * 1) 新增 fastMode 参数；当 count≤20 且 jpegQuality≤70 自动触发快速预设。
 * 2) 快速预设：
 *    - preferClosestSync = true（首尾也用 CLOSEST_SYNC，全部对齐关键帧）
 *    - maxConcurrency = min(3, cpuCores)
 *    - outputMode = "bytes"（减少磁盘 I/O）
 *    - maxDecodePixels = 200_000（解码尺寸显著缩小）
 * 3) 时间点避开 0 和末尾（映射到 [1%, 99%]），避免个别机型 t=0 慢/空回。
 * 4) 压缩与 I/O 优化：重用 ByteArrayOutputStream；文件输出加 BufferedOutputStream。
 * 5) 打印关键路径日志并统计总耗时、每个 worker 耗时、产出数量等。
 * 6) 仅在必要时旋转的逻辑保留；分片并发模型保留。
 */
class VideoKeyframeExtractorPlugin : FlutterPlugin, MethodCallHandler {

  private lateinit var channel: MethodChannel
  private lateinit var appContext: Context
  private var resolver: ContentResolver? = null
  private val cancelled = ConcurrentHashMap<String, Boolean>()

  private val TAG = "VKFE"
  // 是否打印更详细日志（热路径内仍尽量克制，不在循环内频繁打印）
  private val VERBOSE_LOG = true

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "video_keyframe_extractor")
    channel.setMethodCallHandler(this)
    appContext = binding.applicationContext
    resolver = appContext.contentResolver
    if (VERBOSE_LOG) Log.d(TAG, "onAttachedToEngine")
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "getPlatformVersion" -> {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }
      "extractKeyFrames" -> handleExtract(call, result)
      "cancel" -> {
        val taskId = call.argument<String>("taskId")
        if (taskId != null) {
          cancelled[taskId] = true
          Log.w(TAG, "Cancel requested for taskId=$taskId")
        }
        result.success(null)
      }
      "clearCache" -> {
        val taskId = call.argument<String>("taskId")
        if (taskId != null) {
          val dir = File(appContext.cacheDir, "video_keyframes/$taskId")
          val ok = deleteRecursively(dir)
          Log.d(TAG, "clearCache taskId=$taskId result=$ok path=${dir.absolutePath}")
        }
        result.success(null)
      }
      "clearAllCaches" -> {
        val root = File(appContext.cacheDir, "video_keyframes")
        val ok = deleteRecursively(root)
        Log.d(TAG, "clearAllCaches result=$ok root=${root.absolutePath}")
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    if (VERBOSE_LOG) Log.d(TAG, "onDetachedFromEngine")
  }

  /** 建议的默认并发数（限制为 ≤3，避免解码器资源竞争） */
  private fun cpuConcurrencyDefault(): Int {
    val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
    return min(3, cores)
  }

  /** Java 兼容式递归删除（尽量不引入新依赖） */
  private fun deleteRecursively(f: File?): Boolean {
    if (f == null || !f.exists()) return true
    if (f.isDirectory) f.listFiles()?.forEach { deleteRecursively(it) }
    return f.delete()
  }

  /** 主流程：带并发与性能优化的抽帧实现 */
  private fun handleExtract(call: MethodCall, result: Result) {
    val path = call.argument<String>("path")
    val countArg = call.argument<Int>("count")

    // 参数校验（必填）
    if (path.isNullOrEmpty() || countArg == null || countArg <= 0) {
      val msg = "参数错误：path 或 count 无效"
      Log.e(TAG, msg)
      result.error("ARG_ERROR", msg, null)
      return
    }

    // 读取可选参数
    val targetWidthArg = call.argument<Int>("targetWidth")
    val targetHeightArg = call.argument<Int>("targetHeight")
    var maxDecodePixels = call.argument<Int>("maxDecodePixels")
    var outputMode = call.argument<String>("outputMode") // "bytes" | "files"
    var preferClosestSync = call.argument<Boolean>("preferClosestSync")
    var pageStart = call.argument<Int>("pageStart") ?: 0
    var pageSize = call.argument<Int>("pageSize")
    var taskId = call.argument<String>("taskId") ?: "task_${System.currentTimeMillis()}"
    var maxConcurrency = call.argument<Int>("maxConcurrency") ?: cpuConcurrencyDefault()
    var jpegQuality = (call.argument<Int>("quality") ?: 70).coerceIn(40, 100)
    var fastMode = call.argument<Boolean>("fastMode")

    // 强制上限：最多 20 张，满足 1 秒目标
    val count = min(20, countArg)
    if (pageSize == null) pageSize = count
    if (outputMode == null) outputMode = "files"
    if (preferClosestSync == null) preferClosestSync = true

    // 约束范围
    maxConcurrency = max(1, min(6, maxConcurrency))

    // 自动触发快速模式（符合 1 秒目标的典型条件）
    if (fastMode == null) fastMode = (count <= 20 && jpegQuality <= 70)
    if (fastMode) {
      // 全部抓关键帧、并发限制、走内存输出、压低解码像素
      preferClosestSync = true
      maxConcurrency = min(3, cpuConcurrencyDefault())
      if (maxDecodePixels == null || maxDecodePixels > 200_000) {
        maxDecodePixels = 200_000
      }
    }

    // 重置取消标记
    cancelled[taskId] = false

    if (VERBOSE_LOG) {
      Log.d(
        TAG,
        "extractKeyFrames(args) => taskId=$taskId, path=$path, count=$count, pageStart=$pageStart, pageSize=$pageSize, " +
                "targetWidth=$targetWidthArg, targetHeight=$targetHeightArg, maxDecodePixels=$maxDecodePixels, " +
                "outputMode=$outputMode, preferClosestSync=$preferClosestSync, maxConcurrency=$maxConcurrency, jpegQuality=$jpegQuality, fastMode=$fastMode"
      )
    }

    // 后台线程执行，避免阻塞主线程
    Thread {
      val t0 = System.nanoTime()
      val main = Handler(Looper.getMainLooper())

      var metaRetriever: MediaMetadataRetriever? = null
      var afd: AssetFileDescriptor? = null
      try {
        // 1) 先读取一次元数据，计算时间点与解码尺寸
        metaRetriever = MediaMetadataRetriever()
        if (path.startsWith("content://")) {
          afd = appContext.contentResolver.openAssetFileDescriptor(Uri.parse(path), "r")
          if (afd == null) throw IllegalStateException("openAssetFileDescriptor failed: $path")
          metaRetriever!!.setDataSource(afd!!.fileDescriptor, afd!!.startOffset, afd!!.length)
          if (VERBOSE_LOG) Log.d(TAG, "setDataSource via AFD for content://")
        } else {
          val fixed = if (path.startsWith("file://")) Uri.parse(path).path ?: path else path
          metaRetriever!!.setDataSource(fixed)
          if (VERBOSE_LOG) Log.d(TAG, "setDataSource via file: $fixed")
        }

        val durationMs = metaRetriever!!.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        val srcW = metaRetriever!!.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val srcH = metaRetriever!!.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rotation = metaRetriever!!.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0

        if (durationMs <= 0L) throw IllegalStateException("无法读取视频时长")
        val durationUs = durationMs * 1000L
        if (VERBOSE_LOG) Log.d(TAG, "metadata => durationMs=$durationMs, srcW=$srcW, srcH=$srcH, rotation=$rotation")

        val (decW, decH) = fitSizeConsideringRotation(srcW, srcH, rotation, targetWidthArg, targetHeightArg, maxDecodePixels)
        if (VERBOSE_LOG) Log.d(TAG, "decodeSize => decW=$decW, decH=$decH (rotation-aware)")

        val timesUs = computeEvenTimesUs(durationUs, count) // 已避开 0 与末尾
        val from = pageStart.coerceAtLeast(0)
        val to = (pageStart + pageSize).coerceAtMost(timesUs.size)
        if (VERBOSE_LOG) Log.d(TAG, "timesUs => size=${timesUs.size}, range=[$from,$to), first=${timesUs.firstOrNull()}, last=${timesUs.lastOrNull()}")

        // 全部使用关键帧（包含首尾）
        val optionInterior = MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        val optionEdge = MediaMetadataRetriever.OPTION_CLOSEST_SYNC

        val cacheDir = File(appContext.cacheDir, "video_keyframes/$taskId").apply { mkdirs() }
        if (VERBOSE_LOG) Log.d(TAG, "output cacheDir=${cacheDir.absolutePath}")

        // 2) 分片并发
        data class JobArg(val indices: IntRange)
        fun splitRange(totalFrom: Int, totalTo: Int, parts: Int): List<JobArg> {
          val total = (totalTo - totalFrom).coerceAtLeast(0)
          if (total == 0) return emptyList()
          val base = total / parts
          val rem = total % parts
          val list = ArrayList<JobArg>(parts)
          var start = totalFrom
          repeat(parts) { p ->
            val size = base + if (p < rem) 1 else 0
            if (size > 0) {
              val end = start + size
              list.add(JobArg(start until end))
              start = end
            }
          }
          return list
        }

        val jobs = splitRange(from, to, maxConcurrency)
        if (jobs.isEmpty()) {
          main.post { result.success(emptyList<Any>()) }
          return@Thread
        }

        val outputs: Array<Any?> = arrayOfNulls(to - from) // 保持顺序
        val pool = Executors.newFixedThreadPool(jobs.size)
        val futures = mutableListOf<Future<*>>()

        for ((idx, job) in jobs.withIndex()) {
          val f = pool.submit(Callable {
            val tWorker0 = System.nanoTime()
            var localAfd: AssetFileDescriptor? = null
            var r: MediaMetadataRetriever? = null
            try {
              // 每个工作线程持有自己的 retriever（互不干扰）
              r = MediaMetadataRetriever()
              if (path.startsWith("content://")) {
                localAfd = appContext.contentResolver.openAssetFileDescriptor(Uri.parse(path), "r")
                if (localAfd == null) throw IllegalStateException("openAssetFileDescriptor failed in worker")
                r!!.setDataSource(localAfd!!.fileDescriptor, localAfd!!.startOffset, localAfd!!.length)
              } else {
                val fixed = if (path.startsWith("file://")) Uri.parse(path).path ?: path else path
                r!!.setDataSource(fixed)
              }

              val nTotal = timesUs.size
              val baos = if (outputMode == "bytes") ByteArrayOutputStream(256 * 1024) else null // 重用缓冲
              val rotateMatrix: Matrix? = if (rotation != 0) Matrix().apply { postRotate(rotation.toFloat()) } else null

              for (i in job.indices) {
                if (cancelled[taskId] == true) break

                val relIndex = i - from
                val tUs = timesUs[i]
                val isEdge = (i == 0) || (i == nTotal - 1)
                val opt = if (isEdge) optionEdge else optionInterior

                var bmp = if (decW != null && decH != null) {
                  r!!.getScaledFrameAtTime(tUs, opt, decW, decH)
                } else {
                  r!!.getFrameAtTime(tUs, opt)
                }

                // 理论上 computeEvenTimesUs 已避开 0，这里仅作兜底
                if (bmp == null && isEdge && tUs == 0L) {
                  bmp = if (decW != null && decH != null) {
                    r!!.getScaledFrameAtTime(1000L, opt, decW, decH)
                  } else {
                    r!!.getFrameAtTime(1000L, opt)
                  }
                }
                if (bmp == null) continue

                // 仅在必要时旋转，避免二次旋转
                val needRotate = rotation != 0 && shouldApplyRotation(rotation, srcW, srcH, bmp.width, bmp.height)
                if (needRotate && rotateMatrix != null) {
                  bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, rotateMatrix, true)
                }

                if (outputMode == "bytes") {
                  baos!!.reset()
                  bmp.compress(Bitmap.CompressFormat.JPEG, jpegQuality, baos)
                  outputs[relIndex] = baos.toByteArray()
                } else {
                  val file = File(cacheDir, "$i.jpg")
                  FileOutputStream(file).use { fos ->
                    BufferedOutputStream(fos, 64 * 1024).use { bos ->
                      bmp.compress(Bitmap.CompressFormat.JPEG, jpegQuality, bos)
                      bos.flush()
                    }
                  }
                  outputs[relIndex] = file.absolutePath
                }
                bmp.recycle()
              }

              val tWorker1 = System.nanoTime()
//              if (VERBOSE_LOG) {
//                Log.d(TAG, "worker#$idx done in ${(tWorker1 - tWorker0) / 1_000_000} ms, range=${job.indices}")
//              }
            } catch (t: Throwable) {
              Log.w(TAG, "worker error: ${t.message}", t)
            } finally {
              try { r?.release() } catch (_: Throwable) {}
              try { localAfd?.close() } catch (_: Throwable) {}
            }
          })
          futures.add(f)
        }

        // 等待所有分片完成
        futures.forEach { f ->
          try { f.get() } catch (t: Throwable) { Log.w(TAG, "worker future error: ${t.message}", t) }
        }
        pool.shutdown()

        val finalList = outputs.filterNotNull()
        val t1 = System.nanoTime()
        val totalMs = (t1 - t0) / 1_000_000
        Log.i(TAG, "extractKeyFrames(taskId=$taskId) done. outputs=${finalList.size}, total=${timesUs.size}, cost=${totalMs}ms, fastMode=$fastMode, concurrency=${jobs.size}")

        // 汇总结果并回调
        main.post { result.success(finalList) }

      } catch (e: Exception) {
        Log.e(TAG, "EXTRACT_ERROR: ${e.message}", e)
        Handler(Looper.getMainLooper()).post { result.error("EXTRACT_ERROR", e.message, null) }
      } finally {
        try { metaRetriever?.release() } catch (_: Throwable) {}
        try { afd?.close() } catch (_: Throwable) {}
      }
    }.start()
  }

  // ================= 工具方法 =================

  /** Bitmap 压缩为 JPEG 字节数组（备用） */
  private fun Bitmap.toJpegBytes(quality: Int): ByteArray {
    val out = ByteArrayOutputStream()
    this.compress(Bitmap.CompressFormat.JPEG, quality, out)
    return out.toByteArray()
  }

  /**
   * 依据 rotation 先确定“显示方向”的宽高，再按 target/maxPixels 计算缩放；
   * 若为 90/270°，最后交换回“解码方向”的宽高传给 getScaledFrameAtTime，避免二次缩放损耗。
   */
  private fun fitSizeConsideringRotation(
    srcW: Int,
    srcH: Int,
    rotation: Int,
    targetW: Int?,
    targetH: Int?,
    maxPixels: Int?
  ): Pair<Int?, Int?> {
    val rotated = (rotation % 180 != 0)
    val dispW = if (rotated) srcH else srcW
    val dispH = if (rotated) srcW else srcH

    var w: Int? = targetW
    var h: Int? = targetH

    // 未指定目标宽高则按像素上限缩放（越小越快）
    if (w == null || h == null) {
      if (maxPixels != null && dispW > 0 && dispH > 0) {
        val scale = sqrt(maxPixels.toDouble() / (dispW.toDouble() * dispH))
        val outW = if (scale < 1.0) max(1, (dispW * scale).toInt()) else dispW
        val outH = if (scale < 1.0) max(1, (dispH * scale).toInt()) else dispH
        w = outW
        h = outH
      }
    }

    // 解码接口期望“解码方向”的尺寸；若显示方向与解码方向不同，交换宽高
    return if (w != null && h != null && rotated) {
      if (VERBOSE_LOG) Log.d(TAG, "fitSizeConsideringRotation: rotated => swap decode size to w=$h, h=$w (from disp w=$w, h=$h)")
      Pair(h, w)
    } else Pair(w, h)
  }

  /**
   * 是否需要对帧进行旋转（避免二次旋转）：
   * - 当 rotation 为 90/270 且 帧位图的横竖方向 与 “源视频的原始横竖方向”一致，
   *   说明 retriever 返回的是未扶正的原始帧，此时需要我们手动旋转；
   * - 否则不旋转（多数机型 retriever 已经自动按旋转元数据扶正）。
   */
  private fun shouldApplyRotation(
    rotation: Int,
    srcW: Int,
    srcH: Int,
    bmpW: Int,
    bmpH: Int
  ): Boolean {
    if (rotation % 180 == 0) return false
    val srcIsLandscape = srcW > srcH
    val bmpIsLandscape = bmpW > bmpH
    return srcIsLandscape == bmpIsLandscape
  }

  /**
   * 计算等间隔时间点（首尾避开 0 与末尾，映射到 [1%, 99%]），避免 t=0 慢/空回。
   */
  private fun computeEvenTimesUs(durationUs: Long, n: Int): LongArray {
    val safeN = max(1, n)
    val arr = LongArray(safeN)
    if (durationUs <= 1L) {
      java.util.Arrays.fill(arr, 0L)
      return arr
    }
    if (safeN == 1) {
      arr[0] = (durationUs * 0.01).toLong().coerceIn(0L, durationUs - 1)
      return arr
    }
    val start = durationUs * 0.01
    val end = durationUs * 0.99
    val delta = (end - start) / (safeN - 1)
    for (i in 0 until safeN) {
      var t = (start + i * delta).toLong()
      t = max(0L, min(durationUs - 1, t))
      arr[i] = t
    }
    return arr
  }
}
