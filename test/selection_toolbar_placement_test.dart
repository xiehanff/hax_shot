import 'package:hax_shot/features/capture/selection_toolbar_placement.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  const viewport = Rect.fromLTWH(0, 0, 1000, 800);
  const toolbar = Size(260, 58);

  test('places toolbar below a selection near the top', () {
    final placement = resolveSelectionToolbarPlacement(
      selection: const Rect.fromLTWH(300, 80, 200, 120),
      viewport: viewport,
      toolbarSize: toolbar,
    );

    expect(placement.placeBelow, isTrue);
    expect(placement.centeredInSelection, isFalse);
    expect(placement.offset.dx, 270);
    expect(placement.offset.dy, 210);
  });

  test('places toolbar above a selection near the bottom', () {
    final placement = resolveSelectionToolbarPlacement(
      selection: const Rect.fromLTWH(300, 620, 200, 100),
      viewport: viewport,
      toolbarSize: toolbar,
    );

    expect(placement.placeBelow, isFalse);
    expect(placement.centeredInSelection, isFalse);
    expect(placement.offset.dx, 270);
    expect(placement.offset.dy, 552);
  });

  test('centers toolbar inside a selection with no stable side space', () {
    final placement = resolveSelectionToolbarPlacement(
      selection: const Rect.fromLTWH(40, 100, 920, 620),
      viewport: viewport,
      toolbarSize: toolbar,
    );

    expect(placement.centeredInSelection, isTrue);
    expect(placement.offset.dx, 370);
    expect(placement.offset.dy, 381);
  });

  test('follows a selection near the left edge', () {
    final placement = resolveSelectionToolbarPlacement(
      selection: const Rect.fromLTWH(20, 120, 80, 100),
      viewport: viewport,
      toolbarSize: toolbar,
    );

    expect(placement.offset.dx, 0);
  });

  test('follows a selection near the right edge', () {
    final placement = resolveSelectionToolbarPlacement(
      selection: const Rect.fromLTWH(900, 120, 80, 100),
      viewport: viewport,
      toolbarSize: toolbar,
    );

    expect(placement.offset.dx, 740);
  });

  testWidgets('delegate keeps toolbar intrinsic size before positioning', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: CaptureToolbarLayoutDelegate(
                  selection: Rect.fromLTWH(300, 80, 200, 120),
                ),
                child: SizedBox(width: 260, height: 58),
              ),
            ),
          ],
        ),
      ),
    );

    final toolbarBox = tester.renderObject<RenderBox>(find.byType(SizedBox));
    expect(toolbarBox.size, toolbar);
    expect(toolbarBox.localToGlobal(Offset.zero), const Offset(270, 210));

    addTearDown(() => tester.binding.setSurfaceSize(null));
  });
}
