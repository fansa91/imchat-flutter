import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imchat/src/models.dart';
import 'package:imchat/src/settings.dart';
import 'package:imchat/src/store.dart';
import 'package:imchat/src/ui/image_bubble.dart';
import 'package:imchat/src/ui/message_item.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回归：消息气泡上的长按必须弹出菜单（v0.2.1 曾被 Tooltip 抢走长按）
void main() {
  testWidgets('long-press on image / unknown bubbles opens the menu', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = (await tester.runAsync(Settings.load))!;
    final store = ChatStore(settings);
    store.me = const User(id: 1, nickname: '我');
    final menus = <int>[];

    Widget item(Message m) => MessageItem(
          m: m,
          isGroup: false,
          first: true,
          last: true,
          highlighted: false,
          onMenu: (m) => menus.add(m.msgType),
          onJump: (_) {},
          onReedit: (_) {},
        );

    final image = Message(
      conversationId: 3,
      seq: 0,
      senderId: 1,
      clientMsgId: 'img',
      msgType: msgImage,
      content: const ImageContent(key: '', mime: 'image/jpeg', size: 10, width: 400, height: 300).encode(),
      createdAt: DateTime.now(),
      status: MsgStatus.sending,
    );
    final unknown = Message(
      conversationId: 3,
      seq: 5,
      senderId: 2,
      clientMsgId: 'u',
      msgType: 42,
      content: '{}',
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        home: Scaffold(body: Column(children: [item(image), item(unknown)])),
      ),
    ));
    await tester.pump();

    expect(find.text('[不支持的消息，请升级]'), findsOneWidget);
    await tester.longPress(find.text('[不支持的消息，请升级]'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(menus, [42]);

    await tester.longPress(find.byType(ImageBubble));
    await tester.pump(const Duration(milliseconds: 100));
    expect(menus, [42, msgImage]);
  });
}
