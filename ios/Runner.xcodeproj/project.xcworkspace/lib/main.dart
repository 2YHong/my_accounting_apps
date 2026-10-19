import 'dart:async';
import 'sync/pocket_sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'pages/home_page.dart';
import 'pages/statistics_page.dart';
import 'pages/assets_page.dart';
import 'pages/profile_page.dart';
import 'services/bill_csv_service.dart';
import 'models/app_settings.dart';
import 'services/recurring_notifications.dart';
import 'services/recurring_reminder_service.dart';
import 'pages/recurring_bills_page.dart';
import 'components/recurring_reminder_control.dart';
import 'services/data_restore_notifications.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['中文离线语音模型 Zipformer 14M'],
      await rootBundle.loadString('assets/voice/zh-14m/LICENSE'));
  });
  await AppSettings.instance.load();
  await RecurringReminderService.instance.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  ThemeData _theme(Brightness brightness, Color seed) {
    final dark = brightness == Brightness.dark;
    final gentle = AppSettings.instance.eyeComfort;
    // Dark mode has one neutral palette, independent of the daytime accent.
    final base = ColorScheme.fromSeed(
      seedColor: dark ? const Color(0xFF78818F)
        : gentle ? Color.lerp(seed, const Color(0xFF77857C), .35)! : seed,
      brightness: brightness);
    final colors = dark ? base.copyWith(
      primary: const Color(0xFF93A0B3), onPrimary: const Color(0xFF1F2834),
      primaryContainer: const Color(0xFF2E3642), onPrimaryContainer: const Color(0xFFC0CBD9),
      secondary: const Color(0xFFABAEB8), secondaryContainer: const Color(0xFF303138),
      tertiary: const Color(0xFFB5AFA3), tertiaryContainer: const Color(0xFF37342F),
      surface: const Color(0xFF1B1B1E), onSurface: const Color(0xFFC6C6CD),
      onSurfaceVariant: const Color(0xFFA8A8B1),
      surfaceContainerLowest: const Color(0xFF141416),
      surfaceContainerLow: const Color(0xFF202023), surfaceContainer: const Color(0xFF242427),
      surfaceContainerHigh: const Color(0xFF29292D), surfaceContainerHighest: const Color(0xFF303034),
      outline: const Color(0xFF767680), outlineVariant: const Color(0xFF3C3C43),
    ) : gentle ? base.copyWith(
      surface: const Color(0xFFFAF9F3), onSurface: const Color(0xFF303A34),
      surfaceContainerLowest: const Color(0xFFF3F3EB), surfaceContainerLow: const Color(0xFFF0F1E9),
      surfaceContainer: const Color(0xFFECEFE7), surfaceContainerHigh: const Color(0xFFE7EBE2),
      surfaceContainerHighest: const Color(0xFFE1E6DC),
    ) : base;
    return ThemeData(useMaterial3: true, colorScheme: colors,
      scaffoldBackgroundColor: colors.surfaceContainerLowest,
      appBarTheme: AppBarTheme(backgroundColor: colors.surfaceContainerLowest, elevation: 0),
      cardTheme: CardThemeData(color: colors.surface, elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20)))),
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: colors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16))),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))));
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: AppSettings.instance, builder: (context, _) {
    final settings = AppSettings.instance;
    return MaterialApp(title: '我的记账本', debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light, settings.seed), darkTheme: _theme(Brightness.dark, settings.seed),
      themeMode: settings.darkMode ? ThemeMode.dark : ThemeMode.light,
      home: const MainNavigationPage());
  });
}

class MainNavigationPage extends StatefulWidget {
  const MainNavigationPage({super.key});
  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    billDataRevision.addListener(_onBillsImported);
    WidgetsBinding.instance.addObserver(this);
    recurringDataRevision.addListener(_onRecurringChanged);
    backupDataRevision.addListener(_onDataRestored);
    RecurringReminderService.instance.addListener(_onReminderEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onRecurringChanged();
      _onReminderEvent();
      unawaited(PocketSyncController.instance.onResume());
    });
  }
  void _onRecurringChanged() { RecurringReminderService.instance.refresh(); }
  void _onReminderEvent() {
    final reminders = RecurringReminderService.instance;
    if (!mounted || !reminders.openRequested) return;
    reminders.openRequested = false;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
      const RecurringBillsPage(reminderControl: RecurringReminderControl())));
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onRecurringChanged();
      unawaited(PocketSyncController.instance.onResume());
    } else {
      PocketSyncController.instance.pause();
    }
  }
  void _onBillsImported() {
    if (mounted) setState(() => _statisticsRevision++);
  }
  Future<void> _onDataRestored() async {
    final revision = ++_restoreRevision;
    var settingsReloaded = true;
    try {
      await AppSettings.instance.load();
    } catch (_) {
      settingsReloaded = false;
    }
    if (!mounted || revision != _restoreRevision) return;
    // Recreate all four pages so cached users, accounts and ledger choices
    // cannot survive replacement of the complete local database.
    setState(() {
      _pageRevision = revision;
      _statisticsRevision++;
    });
    await RecurringReminderService.instance.reloadSavedPreference();
    if (!mounted || revision != _restoreRevision) return;
    if (!settingsReloaded) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('数据已恢复，显示设置暂未刷新，请重新打开软件')));
    }
  }
  @override
  void dispose() {
    billDataRevision.removeListener(_onBillsImported);
    WidgetsBinding.instance.removeObserver(this);
    recurringDataRevision.removeListener(_onRecurringChanged);
    backupDataRevision.removeListener(_onDataRestored);
    RecurringReminderService.instance.removeListener(_onReminderEvent);
    super.dispose();
  }
  int _currentIndex = 0;
  int _statisticsRevision = 0;
  int _restoreRevision = 0;
  int _pageRevision = 0;
  void _selectPage(int index) {
    setState(() {
      if (index == 1 && _currentIndex != 1) _statisticsRevision++;
      _currentIndex = index;
    });
  }
  static const _labels = ['账单', '统计', '资产', '我的'];
  static const _icons = [Icons.receipt_long_outlined, Icons.bar_chart_rounded,
    Icons.account_balance_wallet_outlined, Icons.person_outline_rounded];
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final wide = constraints.maxWidth >= 800;
    return Scaffold(
      body: Row(children: [
        if (wide) ...[
          NavigationRail(
            extended: constraints.maxWidth >= 1100, selectedIndex: _currentIndex,
            onDestinationSelected: _selectPage,
            leading: const Padding(padding: EdgeInsets.symmetric(vertical: 24),
              child: Icon(Icons.savings_outlined, size: 32)),
            destinations: List.generate(4, (i) => NavigationRailDestination(
              icon: Icon(_icons[i]), label: Text(_labels[i])))),
          const VerticalDivider(width: 1),
        ],
        Expanded(child: IndexedStack(key: ValueKey(_pageRevision), index: _currentIndex, children: [
          const HomePage(), StatisticsPage(refreshToken: _statisticsRevision), const AssetsPage(), const ProfilePage(),
        ])),
      ]),
      bottomNavigationBar: wide ? null : NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _selectPage,
        destinations: List.generate(4, (i) => NavigationDestination(
          icon: Icon(_icons[i]), label: _labels[i]))),
    );
  });
}

