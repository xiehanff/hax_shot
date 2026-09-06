import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

import 'annotation.dart';

/// Interactive editing surface for the text annotation currently being typed.
///
/// The editor is an overlay only. Its border, external corner handles, move
/// handle and close button are never painted by [ScreenshotCanvas], so they
/// cannot leak into the exported PNG.
final class TextAnnotationEditor extends StatelessWidget {
  const TextAnnotationEditor({
    required this.annotation,
    required this.controller,
    required this.focusNode,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onDelete,
    super.key,
  });

  /// Extra width reserved for the corner handles outside the text box.
  static const horizontalInset = 20.0;

  /// Space above the text box for the close button and move handle.
  static const topInset = 56.0;

  /// Extra height reserved for the bottom corner handles.
  static const bottomInset = 20.0;

  final ScreenshotAnnotation annotation;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<TextResizeHandle> onResizeStart;
  final void Function(TextResizeHandle handle, Offset delta) onResizeUpdate;
  final ValueChanged<TextResizeHandle> onResizeEnd;
  final VoidCallback onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final rect = annotation.rect;
    final showFrame = annotation.text.isNotEmpty;
    final boxLeft = horizontalInset;
    final boxTop = topInset;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: boxLeft,
          top: boxTop,
          width: rect.width,
          height: rect.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: showFrame
                  ? Border.all(color: annotation.color, width: 1.5)
                  : null,
              color: showFrame
                  ? Colors.black.withValues(alpha: 0.08)
                  : Colors.transparent,
            ),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              maxLines: null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                color: annotation.color,
                fontSize: annotation.fontSize,
                height: 1,
              ),
              cursorColor: annotation.color,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
        if (showFrame) ...[
          _ResizeHandle(
            handle: TextResizeHandle.topLeft,
            left: boxLeft - _ResizeHandle.size,
            top: boxTop - _ResizeHandle.size,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
          _ResizeHandle(
            handle: TextResizeHandle.topRight,
            left: boxLeft + rect.width,
            top: boxTop - _ResizeHandle.size,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
          _ResizeHandle(
            handle: TextResizeHandle.bottomLeft,
            left: boxLeft - _ResizeHandle.size,
            top: boxTop + rect.height,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
          _ResizeHandle(
            handle: TextResizeHandle.bottomRight,
            left: boxLeft + rect.width,
            top: boxTop + rect.height,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
          Positioned(
            left: boxLeft + (rect.width - _MoveHandle.width) / 2,
            top: boxTop - _MoveHandle.height - 10,
            child: _MoveHandle(
              onMoveStart: onMoveStart,
              onMoveUpdate: onMoveUpdate,
              onMoveEnd: onMoveEnd,
            ),
          ),
          Positioned(
            left: boxLeft + (rect.width - _CloseButton.size) / 2,
            top: 0,
            child: _CloseButton(onPressed: onDelete),
          ),
        ],
      ],
    );
  }
}

final class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.handle,
    required this.left,
    required this.top,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  static const size = 18.0;

  final TextResizeHandle handle;
  final double left;
  final double top;
  final ValueChanged<TextResizeHandle> onResizeStart;
  final void Function(TextResizeHandle handle, Offset delta) onResizeUpdate;
  final ValueChanged<TextResizeHandle> onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final cursor = switch (handle) {
      TextResizeHandle.topLeft => SystemMouseCursors.resizeUpLeft,
      TextResizeHandle.topRight => SystemMouseCursors.resizeUpRight,
      TextResizeHandle.bottomLeft => SystemMouseCursors.resizeDownLeft,
      TextResizeHandle.bottomRight => SystemMouseCursors.resizeDownRight,
    };
    return Positioned(
      left: left,
      top: top,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          key: ValueKey('text-resize-${handle.name}'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => onResizeStart(handle),
          onPanUpdate: (details) => onResizeUpdate(handle, details.delta),
          onPanEnd: (_) => onResizeEnd(handle),
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black54, width: 1),
              ),
              child: const SizedBox.square(dimension: 8),
            ),
          ),
        ),
      ),
    );
  }
}

final class _MoveHandle extends StatelessWidget {
  const _MoveHandle({
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
  });

  static const width = 22.0;
  static const height = 22.0;

  final VoidCallback onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        key: const ValueKey('text-move-handle'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onMoveStart(),
        onPanUpdate: (details) => onMoveUpdate(details.delta),
        onPanEnd: (_) => onMoveEnd(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.9),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white70),
          ),
          child: const Center(
            child: HugeIcon(
              icon: HugeIcons.strokeRoundedMove,
              color: Colors.white,
              size: 16,
              strokeWidth: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

final class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  static const size = 22.0;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '删除文字标注',
      child: GestureDetector(
        key: const ValueKey('text-delete-button'),
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.9),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white70),
          ),
          child: const SizedBox(
            width: size,
            height: size,
            child: Center(
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedCancel01,
                color: Colors.white,
                size: 14,
                strokeWidth: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
