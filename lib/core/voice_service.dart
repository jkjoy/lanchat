import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 语音消息：录制音频存为 m4a 临时文件，随后交给文件传输通道发送。
///
/// 仅桌面(Windows/macOS)与移动(Android/iOS)可用；web 不受支持，
/// 调用 [start] 前可用 [supported] 判断。
///
/// [AudioRecorder] 首次真正使用时才创建（懒加载），避免纯 Dart 测试
/// 环境中触发平台通道。
class VoiceService {
  AudioRecorder? _recorder;
  bool _recording = false;
  String? _recordingPath;

  AudioRecorder get _r => _recorder ??= AudioRecorder();

  /// 是否支持录音。
  Future<bool> supported() async {
    try {
      return await _r.isEncoderSupported(AudioEncoder.aacLc);
    } catch (_) {
      return false;
    }
  }

  /// 开始录音（m4a/aac，44.1kHz 单声道）。返回是否成功开始。
  Future<bool> start() async {
    if (_recording) return false;
    try {
      if (!(await _r.hasPermission())) {
        debugPrint('[record] 无麦克风权限');
        return false;
      }
      final docs = await getApplicationDocumentsDirectory();
      await Directory(docs.path).create(recursive: true);
      final path =
          '${docs.path}/lanchat_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _r.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          numChannels: 1,
          sampleRate: 44100,
          bitRate: 64000,
        ),
        path: path,
      );
      _recordingPath = path;
      _recording = true;
      debugPrint('[record] 开始录音: $path');
      return true;
    } catch (e) {
      debugPrint('[record] 启动录音失败: $e');
      return false;
    }
  }

  /// 停止录音。返回录音文件路径；失败返回 null。
  Future<String?> stop() async {
    if (!_recording) return null;
    _recording = false;
    try {
      final path = await _r.stop();
      debugPrint('[record] 停止录音: $path');
      return path ?? _recordingPath;
    } catch (e) {
      debugPrint('[record] 停止录音失败: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    if (_recording) {
      await _r.stop();
      _recording = false;
    }
    await _recorder?.dispose();
    _recorder = null;
  }
}