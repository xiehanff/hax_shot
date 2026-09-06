import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../native/native_bridge.dart';
import 'capture_toolbar.dart';
import 'screenshot_canvas.dart';
import 'selection_toolbar_placement.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  ui.Image? _image;
  Offset? _dragStart;
  Rect? _selection;
  String? _message;
  bool _loading = true;
  bool _busy = false;
  bool _selectionCommitted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    try {
      final path = await NativeBridge.instance.captureScreen();
      final file = File(path);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      try {
        await file.delete();
      } on Object {
        // The temporary file is safe to leave behind if another process owns it.
      }

      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image = frame.image;
        _loading = false;
        _message = null;
      });
      // Reveal the frozen screenshot only after native capture completes.
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = '截图失败：$error';
      });
      await windowManager.show();
      await windowManager.focus();
    }
  }

  void _startSelection(ScreenshotLayout layout, Offset point) {
    final start = layout.clampToImage(point);
    setState(() {
      _dragStart = start;
      _selection = null;
      _selectionCommitted = false;
      _message = null;
    });
  }

  void _updateSelection(ScreenshotLayout layout, Offset point) {
    final start = _dragStart;
    if (start == null) return;
    final current = layout.clampToImage(point);
    setState(() {
      // Keep the rectangle visible while dragging, but do not show action
      // buttons until onPanEnd commits this selection.
      _selection = Rect.fromPoints(start, current);
      _selectionCommitted = false;
    });
  }

  void _finishSelection() {
    final selection = _selection;
    _dragStart = null;
    if (selection == null || selection.width < 4 || selection.height < 4) {
      setState(() {
        _selection = null;
        _selectionCommitted = false;
        _message = '请拖动选择一个更大的区域';
      });
      return;
    }

    setState(() {
      _selectionCommitted = true;
    });
  }

  Future<Uint8List> _renderSelection(
    ScreenshotLayout layout,
    Rect selection,
  ) async {
    final image = _image;
    if (image == null) {
      throw const NativeBridgeException('截图图片尚未准备好');
    }

    final source = layout.toPixelRect(selection);
    final width = source.width.round().clamp(1, image.width);
    final height = source.height.round().clamp(1, image.height);
    final destination = Rect.fromLTWH(
      0,
      0,
      width.toDouble(),
      height.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        source.left,
        source.top,
        width.toDouble(),
        height.toDouble(),
      ),
      destination,
      Paint()..filterQuality = FilterQuality.high,
    );

    final picture = recorder.endRecording();
    final cropped = await picture.toImage(width, height);
    picture.dispose();
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    if (data == null) {
      throw const NativeBridgeException('PNG 编码失败');
    }
    return data.buffer.asUint8List();
  }

  Future<void> _save(ScreenshotLayout layout) async {
    final selection = _selection;
    if (selection == null || _busy) return;

    setState(() {
      _busy = true;
      _message = '正在生成 PNG…';
    });

    try {
      final png = await _renderSelection(layout, selection);
      final home = Platform.environment['HOME'];
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'PNG 图片',
            extensions: ['png'],
            mimeTypes: ['image/png'],
          ),
        ],
        initialDirectory: home == null ? null : '$home/Pictures',
        suggestedName: 'easy-shot-${_timestamp()}.png',
        confirmButtonText: '保存',
      );
      if (location == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final path = location.path.toLowerCase().endsWith('.png')
          ? location.path
          : '${location.path}.png';
      await File(path).writeAsBytes(png, flush: true);
      await _closeCapture();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '保存失败：$error';
      });
    }
  }

  Future<void> _copy(ScreenshotLayout layout) async {
    final selection = _selection;
    if (selection == null || _busy) return;

    setState(() {
      _busy = true;
      _message = '正在复制…';
    });

    try {
      final png = await _renderSelection(layout, selection);
      await NativeBridge.instance.copyPngToClipboard(png);
      await _closeCapture();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '复制失败：$error';
      });
    }
  }

  Future<void> _cancel() => _closeCapture();

  Future<void> _closeCapture() async {
    if (mounted) {
      setState(() => _busy = true);
    }
    await windowManager.close();
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (_loading || image == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: _message == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _cancel();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final layout = ScreenshotLayout.fromViewport(
                constraints.biggest,
                image,
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  ScreenshotCanvas(
                    image: image,
                    layout: layout,
                    selection: _selection,
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) =>
                        _startSelection(layout, details.localPosition),
                    onPanUpdate: (details) =>
                        _updateSelection(layout, details.localPosition),
                    onPanEnd: (_) => _finishSelection(),
                    child: const SizedBox.expand(),
                  ),
                  if (_selection == null && _message == null)
                    const IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: EdgeInsets.only(top: 28),
                          child: Text(
                            '拖动鼠标框选截图区域 · Esc 取消',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              shadows: [Shadow(blurRadius: 4)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_message != null)
                    IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 28),
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: Color(0xDD202124),
                              borderRadius: BorderRadius.all(
                                Radius.circular(8),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Text(_message!),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_selectionCommitted && _selection != null)
                    Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: CaptureToolbarLayoutDelegate(
                          selection: _selection!,
                        ),
                        child: CaptureToolbar(
                          enabled: true,
                          busy: _busy,
                          onCancel: _cancel,
                          onSave: () => _save(layout),
                          onCopy: () => _copy(layout),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
