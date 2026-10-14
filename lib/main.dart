import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'src/settings.dart';
import 'src/store.dart';
import 'src/ui/home_page.dart';
import 'src/ui/login_page.dart';
import 'src/ui/voice_player.dart';

/// 动态取色不可用时的种子色
const Color seedColor = Color(0xFF2F6FED);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final store = ChatStore(settings);
  unawaited(store.boot());
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider(create: (_) => VoicePlayer()),
      ],
      child: const IMChatApp(),
    ),
  );
}

ThemeData buildTheme(ColorScheme scheme) => ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );

class IMChatApp extends StatelessWidget {
  const IMChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<Settings, ThemeMode>((s) => s.themeMode);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final light = lightDynamic?.harmonized() ?? ColorScheme.fromSeed(seedColor: seedColor);
        final dark = darkDynamic?.harmonized() ??
            ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark);
        return MaterialApp(
          title: 'IMChat',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildTheme(light),
          darkTheme: buildTheme(dark),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const _Root(),
        );
      },
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  StreamSubscription<String>? _toastSub;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _toastSub = context.read<ChatStore>().toasts.listen((t) {
      _messenger.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 3)));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _toastSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final store = context.read<ChatStore>();
    if (state == AppLifecycleState.resumed) {
      store.onResume();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      store.onPause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    Widget child;
    if (store.booting) {
      child = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (store.me == null) {
      child = const LoginPage();
    } else {
      child = const HomePage();
    }
    return ScaffoldMessenger(key: _messenger, child: child);
  }
}
