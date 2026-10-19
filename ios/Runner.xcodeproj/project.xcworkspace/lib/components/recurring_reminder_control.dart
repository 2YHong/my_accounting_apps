import 'package:flutter/material.dart';
import '../services/recurring_reminder_service.dart';

class RecurringReminderControl extends StatelessWidget {
  const RecurringReminderControl({super.key});
  @override
  Widget build(BuildContext context) {
    final reminders = RecurringReminderService.instance;
    return ListenableBuilder(listenable: reminders, builder: (context, _) => Card(
      child: Column(children: [
        SwitchListTile(title: const Text('每月到期提醒'),
          subtitle: Text(reminders.supported
            ? '到期当天上午9点左右提醒；允许通知后生效'
            : '手机支持到期通知，当前设备可查看待确认项'),
          value: reminders.enabled,
          onChanged: reminders.busy || !reminders.supported ? null : (value) async {
            final success = await reminders.setEnabled(value);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success
              ? value ? '已开启到期提醒' : '已关闭通知，待确认项仍会保留'
              : reminders.error ?? '提醒设置失败，请重试')));
          }),
        if (reminders.error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(reminders.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: reminders.busy || !reminders.supported ? null : () async {
            final sent = await reminders.showTest();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(sent
              ? '请查看手机通知栏，点击测试提醒可打开固定收支'
              : reminders.error ?? '测试提醒发送失败')));
          }, icon: const Icon(Icons.notifications_active_outlined, size: 18),
          label: const Text('发送测试提醒'))),
      ])));
  }
}
