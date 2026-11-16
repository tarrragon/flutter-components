// PixelMotion 契約（元件庫規格 4.1）的測試點，每一組對應〈測試點〉的一條。
// 用合成場景：三個 1 × 1 到 3 × 3 格的色塊，不依賴任何 app 的圖。
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_components/flutter_components.dart';
import 'package:flutter_test/flutter_test.dart';

const _interval = Duration(milliseconds: 100);

ui.Picture _square(Rect r, Color color) {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(r, Paint()..color = color..isAntiAlias = false);
  return rec.endRecording();
}

final _back = _square(const Rect.fromLTWH(0, 0, 16, 10), const Color(0xFF223344));
final _parts = [
  PixelPart(_square(const Rect.fromLTWH(2, 2, 3, 3), const Color(0xFFAA3333)), const Rect.fromLTWH(2, 2, 3, 3)),
  PixelPart(_square(const Rect.fromLTWH(7, 4, 2, 2), const Color(0xFF33AA33)), const Rect.fromLTWH(7, 4, 2, 2)),
  PixelPart(_square(const Rect.fromLTWH(12, 6, 1, 1), const Color(0xFF3333AA)), const Rect.fromLTWH(12, 6, 1, 1)),
];

/// 事件動作：前 5 個姿勢間隔第一個部件往右 1 格、往上 1 格，之後結束。
PixelPose _hop(Duration elapsed) {
  if (elapsed > _interval * 5) return const PixelPose([Offset.zero, Offset.zero, Offset.zero], done: true);
  return const PixelPose([Offset(1, -1), Offset.zero, Offset.zero]);
}

/// 持續動作：每個間隔第二個部件左右交替 1 格。
PixelPose _sway(Duration elapsed) {
  final n = elapsed.inMicroseconds ~/ _interval.inMicroseconds;
  return PixelPose([Offset.zero, Offset(n.isEven ? 1 : -1, 0), Offset.zero]);
}

void main() {
  final scene = PixelScene.build(widthCells: 16, heightCells: 10, cell: 4, back: _back, parts: _parts);
  bool scheduled() => SchedulerBinding.instance.hasScheduledFrame;
  PixelMotionState stateOf(WidgetTester t) => t.state<PixelMotionState>(find.byType(PixelMotion));
  bool atRest(WidgetTester t) => stateOf(t).pose.value.every((o) => o == Offset.zero);

  Widget event({PixelMotionController? controller, PixelMotionFn motion = _hop}) => PixelMotion(
        variant: PixelMotionVariant.event,
        scene: scene,
        motion: motion,
        controller: controller,
        semanticLabel: '色塊',
      );
  Widget ambient() => PixelMotion(variant: PixelMotionVariant.ambient, scene: scene, motion: _sway);

  Future<void> mountApp(WidgetTester t, Widget child, {ThemeData? theme}) =>
      t.pumpWidget(MaterialApp(theme: theme, home: Scaffold(body: Center(child: child))));
  Future<void> unmount(WidgetTester t) => t.pumpWidget(const SizedBox());

  testWidgets('event 觸發後跑完回到靜止：計時器取消、位移為 0、不排下一幀', (t) async {
    await mountApp(t, event());
    await t.tap(find.byType(PixelMotion));
    expect(stateOf(t).isRunning, isTrue);
    for (var i = 0; i < 20 && stateOf(t).isRunning; i++) {
      await t.pump(_interval);
      expect(scheduled(), isFalse, reason: '第 $i 次推進之後');
    }
    expect(stateOf(t).isRunning, isFalse);
    expect(atRest(t), isTrue);
    await t.pump(const Duration(seconds: 2));
    expect(scheduled(), isFalse);
    await unmount(t);
  });

  testWidgets('一支測試逐一渲染兩個變體與全部狀態', (t) async {
    final controller = PixelMotionController();
    await mountApp(t, event(controller: controller));
    expect(atRest(t), isTrue, reason: 'idle');
    controller.trigger();
    await t.pump();
    expect(atRest(t), isFalse, reason: 'moving');
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(stateOf(t).isFocused, isTrue, reason: 'focused');
    await mountApp(t, ambient());
    await t.pump(const Duration(seconds: 1));
    expect(stateOf(t).isRunning, isTrue, reason: 'ambient moving');
    await mountApp(t, TickerMode(enabled: false, child: ambient()));
    expect(stateOf(t).isRunning, isFalse, reason: 'ambient paused');
    for (final w in [event(), ambient()]) {
      await t.pumpWidget(MediaQuery(data: const MediaQueryData(disableAnimations: true), child: w));
      expect(stateOf(t).isRunning, isFalse, reason: 'reduced');
      expect(atRest(t), isTrue, reason: 'reduced');
    }
    expect(t.takeException(), isNull);
    controller.dispose();
    await unmount(t);
  });

  testWidgets('祖先沒有 Directionality 也能掛載', (t) async {
    await t.pumpWidget(Center(child: event()));
    expect(t.takeException(), isNull);
    await t.pumpWidget(Center(child: ambient()));
    expect(t.takeException(), isNull);
    await unmount(t);
  });

  testWidgets('觸發的當下就套用第一個姿勢', (t) async {
    await t.pumpWidget(Center(child: event()));
    await t.tap(find.byType(PixelMotion));
    await t.pump();
    expect(atRest(t), isFalse);
    await unmount(t);
  });

  testWidgets('ambient 在 TickerMode 關閉時暫停、不排下一幀，開啟後恢復', (t) async {
    Widget host(bool enabled) => Center(child: TickerMode(enabled: enabled, child: ambient()));
    await t.pumpWidget(host(true));
    await t.pump(const Duration(seconds: 1));
    expect(stateOf(t).isRunning, isTrue);
    await t.pumpWidget(host(false));
    expect(stateOf(t).isRunning, isFalse);
    final frozen = stateOf(t).pose.value;
    for (var i = 0; i < 10; i++) {
      await t.pump(_interval);
      expect(scheduled(), isFalse);
    }
    expect(stateOf(t).pose.value, frozen);
    await t.pumpWidget(host(true));
    expect(stateOf(t).isRunning, isTrue);
    await unmount(t);
  });

  testWidgets('減少動態時只顯示基準姿勢、不排下一幀，觸發也不動作', (t) async {
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Center(child: event()),
    ));
    await t.tap(find.byType(PixelMotion));
    await t.pump(_interval);
    expect(stateOf(t).isRunning, isFalse);
    expect(atRest(t), isTrue);
    expect(scheduled(), isFalse);
    await unmount(t);
  });

  testWidgets('event：Tab 取得焦點、Enter 與空白鍵觸發、游標為手形、朗讀為按鈕', (t) async {
    final semantics = t.ensureSemantics();
    await mountApp(t, event());
    final node = t.getSemantics(find.bySemanticsLabel('色塊'));
    expect(node.flagsCollection.isButton, isTrue);

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await mouse.addPointer(location: t.getCenter(find.byType(PixelMotion)));
    await t.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.click);
    await mouse.removePointer();

    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      await t.pump(const Duration(seconds: 2));
      expect(stateOf(t).isRunning, isFalse);
      await t.sendKeyEvent(key);
      await t.pump();
      expect(stateOf(t).isRunning, isTrue, reason: '$key 沒有觸發');
    }
    await unmount(t);
    semantics.dispose();
  });

  testWidgets('小於最小命中區的場景，命中區擴到 hitTarget', (t) async {
    final tiny = PixelScene.build(widthCells: 3, heightCells: 3, cell: 4, back: _back, parts: [_parts[0]]);
    await t.pumpWidget(Center(
      child: PixelMotion(variant: PixelMotionVariant.event, scene: tiny, motion: _hop, semanticLabel: '小'),
    ));
    expect(t.getSize(find.byType(PixelMotion)), const Size(24, 24));
    await unmount(t);
  });

  for (final dpr in [1.0, 2.0]) {
    test('裝置像素比 $dpr：atlas 畫法與逐部件重播 Picture 的畫面逐位元組相同', () async {
      const pose = [Offset(1, -1), Offset(-2, 0), Offset(0, 2)];
      final w = (scene.size.width * dpr).round(), h = (scene.size.height * dpr).round();

      Future<Uint8List> render(void Function(Canvas) paint) async {
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec)..scale(dpr);
        paint(canvas);
        final image = await rec.endRecording().toImage(w, h);
        return (await image.toByteData())!.buffer.asUint8List();
      }

      final atlas = await render((c) {
        paintPixelBack(c, scene);
        paintPixelParts(c, scene, pose);
      });
      final replay = await render((c) {
        c.scale(scene.cell);
        c.drawPicture(_back);
        for (var i = 0; i < _parts.length; i++) {
          c.save();
          c.translate(pose[i].dx, pose[i].dy);
          c.drawPicture(_parts[i].picture);
          c.restore();
        }
      });
      expect(atlas, replay);
    });
  }

  testWidgets('覆寫 motion.poseInterval 之後計時間隔跟著改變', (t) async {
    Future<int> callsIn(Duration window, {ThemeData? theme}) async {
      var calls = 0;
      await mountApp(
        t,
        event(motion: (e) {
          calls++;
          return _sway(e); // 不會結束，計數只看間隔
        }),
        theme: theme,
      );
      await t.tap(find.byType(PixelMotion));
      await t.pump(window);
      await unmount(t);
      return calls;
    }

    expect(await callsIn(const Duration(milliseconds: 400)), 5);
    expect(
      await callsIn(const Duration(milliseconds: 400),
          theme: ThemeData(extensions: const [PixelMotionTheme(poseInterval: Duration(milliseconds: 200))])),
      3,
    );
  });
}
