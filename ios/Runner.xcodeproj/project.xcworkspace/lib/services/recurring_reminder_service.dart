import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../database/database_helper.dart';
import 'recurring_bill_service.dart';

class RecurringReminderService extends ChangeNotifier {
  RecurringReminderService._();
  static final instance = RecurringReminderService._();
  final _plugin = FlutterLocalNotificationsPlugin();
  static const _payload = 'recurring_confirmation';
  static const _preference = 'recurring_monthly_reminders';
  static const _scheduleError = '到期通知安排失败，可在首页查看固定收支并稍后重试';
  bool enabled = false;
  bool ready = false;
  bool busy = false;
  bool openRequested = false;
  String? error;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  bool get supported => !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> initialize() async {
    if (!supported || ready) return;
    try {
      tz_data.initializeTimeZones();
      enabled = (await SharedPreferences.getInstance()).getBool(_preference) ?? false;
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_accounting'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false,
          requestBadgePermission: false, requestSoundPermission: false)),
        onDidReceiveNotificationResponse: (response) {
          if (response.payload == _payload) { openRequested = true; notifyListeners(); }
        });
      final launched = await _plugin.getNotificationAppLaunchDetails();
      if (launched?.didNotificationLaunchApp == true &&
        launched?.notificationResponse?.payload == _payload) openRequested = true;
      ready = true;
    } catch (_) {
      error = '通知暂时不可用，仍可在首页查看待确认的固定收支';
    }
    notifyListeners();
  }

  Future<void> reloadSavedPreference() async {
    try {
      enabled = (await SharedPreferences.getInstance()).getBool(_preference) ?? false;
      await initialize();
      // Restoring a setting does not grant OS notification permission.
      // Rebuild schedules without requesting permission automatically.
      await refresh();
    } catch (_) {
      error = '数据已恢复，提醒设置暂未刷新，请重新打开软件';
    }
    notifyListeners();
  }

  Future<bool> setEnabled(bool value) async {
    if (busy || !supported) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await initialize();
      if (!ready) return false;
      if (value) {
        bool allowed = false;
        if (defaultTargetPlatform == TargetPlatform.android) {
          allowed = await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission() ?? false;
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          allowed = await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: false, sound: true) ?? false;
        }
        if (!allowed) {
          error = '未获得通知权限，请在手机设置中允许通知后重试';
          return false;
        }
      }
      final saved = await (await SharedPreferences.getInstance()).setBool(_preference, value);
      if (!saved) throw StateError('Preference was not saved');
      enabled = value;
      await refresh();
      return error == null;
    } catch (_) {
      error = '提醒设置保存失败，请重试';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> refresh() {
    _refreshAgain = true;
    if (_refreshing != null) return _refreshing!;
    return _refreshing = _refreshLoop().whenComplete(() => _refreshing = null);
  }
  Future<void> _refreshLoop() async {
    while (_refreshAgain) {
      _refreshAgain = false;
      if (!supported || !ready) return;
      try {
        await _replaceSchedules();
        if (error == _scheduleError) error = null;
      } catch (_) { error = _scheduleError; }
    }
    notifyListeners();
  }
  Future<void> _replaceSchedules() async {
    // Only this feature's notices are replaced; other notification features are untouched.
    final previous = await _plugin.pendingNotificationRequests();
    for (final item in previous.where((item) => item.payload == _payload)) {
      await _plugin.cancel(item.id);
    }
    if (!enabled) return;
    final service = RecurringBillService(DatabaseHelper());
    final now = DateTime.now();
    final dates = await service.upcomingReminderDates(now: now, months: 6);
    final times = <DateTime>{};
    for (final date in dates) {
      final time = DateTime(date.year, date.month, date.day, 9);
      if (time.isAfter(now)) times.add(time);
    }
    // An item already overdue remains visible in-app and gets one gentle next-day notice.
    if (await service.getPendingCount(now: now) > 0) {
      times.add(DateTime(now.year, now.month, now.day + 1, 9));
    }
    final sorted = times.toList()..sort();
    for (final time in sorted.take(60)) {
      final id = 900000 + time.year * 10000 + time.month * 100 + time.day;
      // The instant is derived from the phone's local calendar then encoded as UTC.
      // No repeating timezone rule is used; schedules are rebuilt after resuming.
      await _plugin.zonedSchedule(id, '固定收支待确认',
        '打开记账本核对本期收支，确认后才会记入账单。',
        tz.TZDateTime.from(time, tz.UTC),
        const NotificationDetails(
          android: AndroidNotificationDetails('recurring_monthly', '固定收支提醒',
            channelDescription: '每月到期提醒确认固定收支',
            importance: Importance.defaultImportance, priority: Priority.defaultPriority,
            visibility: NotificationVisibility.private),
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true)),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle, payload: _payload);
    }
  }

  Future<bool> showTest() async {
    if (!await setEnabled(true)) return false;
    if (!ready) return false;
    try {
      await _plugin.show(900001, '固定收支提醒测试', '提醒已送出，点击可打开固定收支。',
        const NotificationDetails(
          android: AndroidNotificationDetails('recurring_monthly', '固定收支提醒',
            channelDescription: '每月到期提醒确认固定收支',
            importance: Importance.defaultImportance, priority: Priority.defaultPriority),
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true)),
        payload: _payload);
      return true;
    } catch (_) {
      error = '测试提醒发送失败，请检查手机通知设置';
      notifyListeners();
      return false;
    }
  }
}
