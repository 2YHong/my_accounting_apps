import 'dart:async';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../pages/recurring_bills_page.dart';
import '../services/recurring_bill_service.dart';
import '../services/recurring_notifications.dart';
import 'recurring_reminder_control.dart';

class RecurringDueBanner extends StatefulWidget {
  const RecurringDueBanner({super.key});
  @override
  State<RecurringDueBanner> createState() => _RecurringDueBannerState();
}
class _RecurringDueBannerState extends State<RecurringDueBanner> with WidgetsBindingObserver {
  int _count = 0;
  int _request = 0;
  Timer? _midnight;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    recurringDataRevision.addListener(_load);
    _load();
    _scheduleMidnight();
  }
  void _scheduleMidnight() {
    _midnight?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now) + const Duration(seconds: 1), () {
      if (mounted) { _load(); _scheduleMidnight(); }
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) { _load(); _scheduleMidnight(); }
  }
  Future<void> _load() async {
    final request = ++_request;
    try {
      final count = await RecurringBillService(DatabaseHelper()).getPendingCount();
      if (mounted && request == _request) setState(() => _count = count);
    } catch (_) { /* Other accounting functions remain usable if a reminder cannot load. */ }
  }
  @override
  void dispose() {
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    recurringDataRevision.removeListener(_load);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => _count == 0 ? const SizedBox.shrink()
    : Card(margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: ListTile(dense: true, leading: const Icon(Icons.event_repeat_outlined),
        title: Text('固定收支 · $_count笔待确认'),
        trailing: const Icon(Icons.chevron_right), onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
            const RecurringBillsPage(reminderControl: RecurringReminderControl())));
          if (mounted) await _load();
        }));
}
