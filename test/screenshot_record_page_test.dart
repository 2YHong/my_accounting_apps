import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_accounting_app/pages/screenshot_record_page.dart';
import 'package:my_accounting_app/sync/sync_edit_guard.dart';

void main(){
  setUpAll(()async{
    for(final entry in {'ProbeChinese':'C:/Windows/Fonts/msyh.ttc','MaterialIcons':'D:/Flutter/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'}.entries){
      final f=File(entry.value);if(!await f.exists())continue;
      final loader=FontLoader(entry.key);loader.addFont(f.readAsBytes().then(ByteData.sublistView));await loader.load();
    }
  });
  testWidgets('local recognized text is editable and narrow layout is usable',(tester)async{
    await tester.binding.setSurfaceSize(const Size(390,844));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    final boundary=GlobalKey();
    var calls=0;
    await tester.pumpWidget(RepaintBoundary(key:boundary,child:MaterialApp(
      theme:ThemeData(useMaterial3:true,fontFamily:'ProbeChinese'),
      home:ScreenshotRecordPage(recognize:()async{calls++;return '微信支付\n支付成功\n-50.00\n商家：楼下便利店\n2026-10-19 12:30';}))));
    await tester.pumpAndSettle();
    expect(calls,1);expect(find.text('核对账单'),findsOneWidget);
    expect(find.textContaining('微信支付'),findsOneWidget);
    await tester.enterText(find.byType(TextField),'Amount: CNY 50.00\nMerchant: Coffee Shop');
    expect(tester.takeException(),isNull);
    final folder=Platform.environment['VOICE_UI_SHOTS'];
    if(folder!=null)await tester.runAsync(()async{
      final render=boundary.currentContext!.findRenderObject()as RenderRepaintBoundary;
      final image=await render.toImage(pixelRatio:1.5);
      final data=await image.toByteData(format:ui.ImageByteFormat.png);
      final file=File('$folder/screenshot-review.png');await file.parent.create(recursive:true);await file.writeAsBytes(data!.buffer.asUint8List());image.dispose();
    });
    await tester.pumpWidget(const SizedBox());await tester.pump();
    expect(SyncEditGuard.active,isFalse);
  });
  testWidgets('empty recognition gives a retry without writing a bill',(tester)async{
    await tester.pumpWidget(MaterialApp(home:ScreenshotRecordPage(recognize:()async=>'')));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有识别到文字'),findsOneWidget);
    expect(find.byType(TextField),findsOneWidget);
    await tester.pumpWidget(const SizedBox());await tester.pump();
    expect(SyncEditGuard.active,isFalse);
  });
  testWidgets('cancelling picker returns to home without review',(tester)async{
    await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>TextButton(
      onPressed:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>ScreenshotRecordPage(recognize:()async=>null))),
      child:const Text('打开截图')))));
    await tester.tap(find.text('打开截图'));await tester.pumpAndSettle();
    expect(find.byType(ScreenshotRecordPage),findsNothing);
    expect(SyncEditGuard.active,isFalse);
  });
}
