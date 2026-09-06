import 'dart:math' as math;

import 'package:flutter/widgets.dart';

@immutable
final class SelectionToolbarPlacement {
  const SelectionToolbarPlacement({
    required this.offset,
    required this.placeBelow,
    this.centeredInSelection = false,
  });

  final Offset offset;
  final bool placeBelow;
  final bool centeredInSelection;
}

/// Places the action toolbar using the same rules as Plume PDF's AI selection
/// toolbar:
///
/// 1. Prefer below the selection when there is room.
/// 2. Otherwise place it above the selection.
/// 3. If the selection leaves too little room on both sides, center the toolbar
///    inside the selection instead of clamping it to an edge.
///
/// The X coordinate follows the selection center for every placement and is
/// clamped to the visible viewport. This keeps the Save/Copy actions next to
/// a selection even when the user selects near either screen edge.
SelectionToolbarPlacement resolveSelectionToolbarPlacement({
  required Rect selection,
  required Rect viewport,
  required Size toolbarSize,
  double gap = 10,
  double minimumSideSpaceFraction = 0.20,
}) {
  final double maxLeft = viewport.right - toolbarSize.width;
  final double selectionLeft = (selection.center.dx - toolbarSize.width / 2)
      .clamp(viewport.left, math.max(viewport.left, maxLeft));

  final double aboveSpace = selection.top - viewport.top;
  final double belowSpace = viewport.bottom - selection.bottom;
  final double minimumSideSpace = viewport.height * minimumSideSpaceFraction;

  if (aboveSpace < minimumSideSpace && belowSpace < minimumSideSpace) {
    final double maxTop = viewport.bottom - toolbarSize.height;
    final double centeredTop = (selection.center.dy - toolbarSize.height / 2)
        .clamp(viewport.top, math.max(viewport.top, maxTop));
    return SelectionToolbarPlacement(
      offset: Offset(selectionLeft, centeredTop),
      placeBelow: false,
      centeredInSelection: true,
    );
  }

  final double requiredSpace = toolbarSize.height + gap;
  final bool aboveFits = aboveSpace >= requiredSpace;
  final bool belowFits = belowSpace >= requiredSpace;
  final bool placeBelow = belowFits != aboveFits
      ? belowFits
      : belowSpace >= aboveSpace;

  final double preferredTop = placeBelow
      ? selection.bottom + gap
      : selection.top - toolbarSize.height - gap;
  final double maxTop = viewport.bottom - toolbarSize.height;
  final double top = preferredTop.clamp(
    viewport.top,
    math.max(viewport.top, maxTop),
  );

  return SelectionToolbarPlacement(
    offset: Offset(selectionLeft, top),
    placeBelow: placeBelow,
  );
}

/// A layout delegate is used instead of hard-coding a toolbar width. The
/// actual CaptureToolbar contains text labels and can change size with font
/// settings, so the placement algorithm must receive the measured child size.
final class CaptureToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  const CaptureToolbarLayoutDelegate({required this.selection});

  final Rect selection;

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // The parent is the full-screen overlay, but the toolbar itself must keep
    // its intrinsic size so the placement calculation receives real width and
    // height instead of the viewport's tight constraints.
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const double margin = 12;
    final double width = math.max(0, size.width - margin * 2);
    final double height = math.max(0, size.height - margin * 2);
    final Rect viewport = Rect.fromLTWH(margin, margin, width, height);
    return resolveSelectionToolbarPlacement(
      selection: selection,
      viewport: viewport,
      toolbarSize: childSize,
    ).offset;
  }

  @override
  bool shouldRelayout(covariant CaptureToolbarLayoutDelegate oldDelegate) {
    return oldDelegate.selection != selection;
  }
}
