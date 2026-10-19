import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/user.dart';
import '../models/app_settings.dart';
import '../sync/pocket_sync_controller.dart';
import 'ledger_management_page.dart';
import 'category_management_page.dart';
import 'budget_management_page.dart';
import 'data_import_export_page.dart';
import 'import_review_page.dart';
import 'settings_page.dart';
import 'full_backup_page.dart';
import 'pocket_sync_page.dart';
import 'recurring_bills_page.dart';
import '../components/recurring_reminder_control.dart';
import '../widgets/edit_nickname_dialog.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _db = DatabaseHelper();
  final _sync = PocketSyncController.instance;
  late Future<User> _user;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _user = _db.getCurrentUser();
  }

  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  Future<void> _toggleBudget(bool value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await AppSettings.instance.setBudgetEnabled(value);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置保存失败，请重试')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editName(User user) async {
    final id = user.id;
    if (id == null) return;
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EditNicknameDialog(
        initialName: user.username,
        onSave: (value) => _db.updateUsername(id, value),
      ),
    );
    if (name == null || !mounted) return;
    setState(() => _user = _db.getCurrentUser());
  }

  Widget _item(IconData icon, String title, Widget page, {String? subtitle}) =>
      ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(page),
      );

  Widget _section(String title, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, color: Colors.grey),
        ),
      ),
      Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(children: children),
      ),
    ],
  );

  Widget _userCard() => Card(
    margin: const EdgeInsets.all(16),
    child: FutureBuilder<User>(
      future: _user,
      builder: (context, snapshot) {
        final user = snapshot.data;
        final name = user?.username.trim();
        return ListTile(
          leading: CircleAvatar(
            child: Text(
              name == null || name.isEmpty ? '我' : name.characters.first,
            ),
          ),
          title: Text(name == null || name.isEmpty ? '默认用户' : name),
          subtitle: Text(
            _sync.owner == null ? '点击登录云账号' : (_sync.accountEmail ?? '云账号已登录'),
          ),
          onTap: () => _open(const PocketSyncPage(accountOnly: true)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (user != null)
                IconButton(
                  tooltip: '修改昵称',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editName(user),
                ),
              const Icon(Icons.chevron_right),
            ],
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppSettings.instance, _sync]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        children: [
          _userCard(),
          _section('基本管理', [
            _item(Icons.book_outlined, '账本管理', const LedgerManagementPage()),
            _item(
              Icons.category_outlined,
              '分类管理',
              const CategoryManagementPage(),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('启用预算'),
              subtitle: const Text('在首页显示预算和超支状态'),
              value: AppSettings.instance.budgetEnabled,
              onChanged: _saving ? null : _toggleBudget,
            ),
            _item(
              Icons.pie_chart_outline,
              '预算管理',
              const BudgetManagementPage(),
            ),
            _item(
              Icons.schedule,
              '固定收支',
              const RecurringBillsPage(
                reminderControl: RecurringReminderControl(),
              ),
            ),
          ]),
          _section('数据管理', [
            _item(Icons.import_export, '账单导入与导出', const DataImportExportPage()),
            _item(Icons.fact_check_outlined, '待核对账单', const ImportReviewPage()),
            _item(
              Icons.cloud_sync_outlined,
              '云同步',
              const PocketSyncPage(),
              subtitle: '加密同步、密钥与恢复码',
            ),
            _item(
              Icons.lock_outline_rounded,
              '备份与恢复',
              const FullBackupPage(),
              subtitle: '完整的本地加密备份',
            ),
          ]),
          _section('设置', [
            _item(Icons.palette_outlined, '外观设置', const SettingsPage()),
          ]),
          const SizedBox(height: 32),
        ],
      ),
    ),
  );
}
