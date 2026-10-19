import '../services/screenshot_recognition.dart';
import 'screenshot_record_page.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../models/ledger.dart';
import '../models/settings_manager.dart';
import '../models/category.dart';
import '../components/expense_item.dart';
import 'add_record_page.dart';
import 'budget_management_page.dart';
import '../models/app_settings.dart';
import '../services/bill_csv_service.dart';
import '../services/asset_notifications.dart';
import '../services/ledger_notifications.dart';
import 'ledger_management_dialog.dart';
import 'month_picker_dialog.dart';
import 'voice_record_page.dart';
import 'voice_record_review.dart';
import '../widgets/voice_entry_button.dart';
import '../components/recurring_due_banner.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ==================== 状态变量 ====================
  final DatabaseHelper _dbHelper = DatabaseHelper();
  List<ExpenseRecord> _allRecords = [];
  Map<int, String> _categoryNames = {};
  Map<int, Category> _recordCategories = {};
  Map<int, String> _accountNames = {};
  bool get _isSummaryLedger => _ledgers.any(
    (ledger) => ledger.id == _selectedLedgerId && ledger.isDefault == 1,
  );
  List<Ledger> _ledgers = [];
  bool _isLoading = true;
  int _currentMonthOffset = 0;
  int _selectedLedgerId = 1;
  int? _currentUserId;
  double _monthlyBudget = 0.0;

  // ==================== 计算属性 ====================
  DateTime get _selectedDate {
    final now = DateTime.now();
    return DateTime(now.year, now.month + _currentMonthOffset, 1);
  }

  DateTime get _firstDayOfMonth => _selectedDate;

  DateTime get _lastDayOfMonth =>
      DateTime(_selectedDate.year, _selectedDate.month + 1, 0);

  String get _selectedLedgerName {
    final selectedLedger = _ledgers.firstWhere(
      (ledger) => ledger.id == _selectedLedgerId,
      orElse: () => Ledger(id: 1, name: '总账本', isDefault: 1, userId: 1),
    );
    return selectedLedger.name;
  }

  // 计算月度总支出
  double get _monthlyExpense => _calculateMonthlyTotal('expense');

  // 计算月度总收入
  double get _monthlyIncome => _calculateMonthlyTotal('income');

  // 计算预算使用百分比
  double get _budgetUsagePercent {
    if (_monthlyBudget <= 0) return 0.0;
    return (_monthlyExpense / _monthlyBudget).clamp(0.0, 1.0);
  }

  // ==================== 生命周期方法 ====================
  @override
  void initState() {
    super.initState();
    _initData();
    billDataRevision.addListener(_onBillsImported);
    assetAccountsRevision.addListener(_onBillsImported);
    ledgerDataRevision.addListener(_onLedgersChanged);
    budgetDataRevision.addListener(_onBudgetChanged);
    AppSettings.instance.addListener(_onBudgetChanged);
  }

  void _onBudgetChanged() {
    if (mounted) {
      setState(() {});
      _loadBudget();
    }
  }

  void _onBillsImported() {
    if (mounted) _loadRecords();
  }

  Future<void> _onLedgersChanged() async {
    if (!mounted || _currentUserId == null) return;
    await _loadLedgers();
    if (!mounted) return;
    if (!_ledgers.any((l) => l.id == _selectedLedgerId)) {
      final fallback =
          _ledgers.where((l) => l.isDefault == 1).firstOrNull ??
          _ledgers.firstOrNull;
      if (fallback?.id != null) {
        setState(() => _selectedLedgerId = fallback!.id!);
        await LedgerSettingsManager.setCurrentLedgerId(_selectedLedgerId);
      }
    }
    await _loadBudget();
    await _loadRecords();
  }

  @override
  void dispose() {
    billDataRevision.removeListener(_onBillsImported);
    assetAccountsRevision.removeListener(_onBillsImported);
    ledgerDataRevision.removeListener(_onLedgersChanged);
    budgetDataRevision.removeListener(_onBudgetChanged);
    AppSettings.instance.removeListener(_onBudgetChanged);
    super.dispose();
  }

  Widget _buildEntryButtons() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: 'home_manual_entry',
          tooltip: '记一笔',
          onPressed: () => _navigateToAddRecord(context),
          backgroundColor: dark ? scheme.primaryContainer : scheme.primary,
          foregroundColor: dark ? scheme.onPrimaryContainer : scheme.onPrimary,
          elevation: 4,
          shape: const CircleBorder(),
          child: const Icon(Icons.edit_rounded),
        ),
        const SizedBox(width: 12),
        if (ScreenshotRecognition.enabled) ...[
          FloatingActionButton(
            heroTag: 'home_screenshot_entry',
            tooltip: '截图记账',
            backgroundColor: scheme.tertiaryContainer,
            foregroundColor: scheme.onTertiaryContainer,
            onPressed: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) =>
                      ScreenshotRecordPage(defaultLedgerId: _selectedLedgerId),
                ),
              );
              if (saved == true && mounted) await _loadRecords();
            },
            shape: const CircleBorder(),
            child: const Icon(Icons.image_outlined),
          ),
          const SizedBox(width: 12),
        ],
        VoiceEntryButton(
          onRecognized: _reviewVoiceRecord,
          onTypeInstead: (text) => _navigateToVoiceRecord(initialText: text),
        ),
      ],
    );
  }

  // ==================== 初始化方法 ====================
  Future<void> _initData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      // 1. 加载账本列表
      await _loadCurrentUser();
      if (!mounted) return;
      await _loadLedgers();
      if (!mounted) return;

      // 2. 加载用户信息
      // User already loaded before fetching their ledgers.

      // 3. 加载设置中的账本选择
      await _loadSavedSettings();
      if (!mounted) return;

      // 4. 加载预算数据
      await _loadBudget();

      // 5. 加载账单记录
      await _loadRecords();
    } catch (e) {
      print('初始化失败: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 加载当前用户
  Future<void> _loadCurrentUser() async {
    try {
      final user = await _dbHelper.getCurrentUser();
      if (!mounted) return;
      setState(() {
        _currentUserId = user.id;
      });
    } catch (e) {
      print('加载用户失败: $e');
      if (!mounted) return;
      setState(() {
        _currentUserId = 1;
      });
    }
  }

  // 加载账本列表
  Future<void> _loadLedgers() async {
    try {
      final ledgers = await _dbHelper.getAllLedgers(userId: _currentUserId);
      if (!mounted) return;
      setState(() {
        _ledgers = ledgers;
        if (_ledgers.isEmpty) {
          _createDefaultLedger();
        }
      });
    } catch (e) {
      print('加载账本失败: $e');
    }
  }

  // 创建默认账本
  Future<void> _createDefaultLedger() async {
    if (!mounted) return;
    final defaultLedger = Ledger(
      name: '总账本',
      isDefault: 1,
      userId: _currentUserId ?? 1,
    );

    try {
      final id = await _dbHelper.insertLedger(defaultLedger);
      if (!mounted) return;
      setState(() {
        _ledgers.add(
          Ledger(
            id: id,
            name: '总账本',
            isDefault: 1,
            userId: _currentUserId ?? 1,
          ),
        );
        _selectedLedgerId = id;
      });
      await LedgerSettingsManager.setCurrentLedgerId(id);
    } catch (e) {
      print('创建默认账本失败: $e');
    }
  }

  // 加载保存的设置
  Future<void> _loadSavedSettings() async {
    try {
      final savedLedgerId = await LedgerSettingsManager.getCurrentLedgerId();
      if (!mounted) return;
      if (_ledgers.any((ledger) => ledger.id == savedLedgerId)) {
        setState(() {
          _selectedLedgerId = savedLedgerId;
        });
      }

      final savedMonthOffset =
          await LedgerSettingsManager.getCurrentMonthOffset();
      if (!mounted) return;
      setState(() {
        _currentMonthOffset = savedMonthOffset;
      });
    } catch (e) {
      print('加载设置失败: $e');
    }
  }

  // 加载预算
  Future<void> _loadBudget() async {
    final ledgerId = _selectedLedgerId;
    final month = _selectedDate;
    try {
      final budgets = await _dbHelper.getAllBudgets(ledgerId: ledgerId);
      final matching =
          budgets
              .where(
                (b) =>
                    b.categoryId == null &&
                    b.cycle == 'month' &&
                    b.startDate.year == month.year &&
                    b.startDate.month == month.month,
              )
              .toList()
            ..sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
      if (mounted && ledgerId == _selectedLedgerId && month == _selectedDate)
        setState(
          () => _monthlyBudget = matching.isEmpty ? 0 : matching.first.amount,
        );
    } catch (_) {
      if (mounted && ledgerId == _selectedLedgerId && month == _selectedDate)
        setState(() => _monthlyBudget = 0);
    }
  }

  // ==================== 数据加载方法 ====================
  Future<void> _loadRecords() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final categories = await _dbHelper.getAllCategories(
        userId: _currentUserId,
      );
      final accounts = await _dbHelper.getAllAssetAccounts(
        userId: _currentUserId,
      );
      final records = await _dbHelper.getRecordsByDateRange(
        _firstDayOfMonth,
        _lastDayOfMonth,
        ledgerId: _isSummaryLedger ? null : _selectedLedgerId,
        userId: _currentUserId,
      );

      if (!mounted) return;
      setState(() {
        _allRecords = records;
        _recordCategories = {
          for (final c in categories)
            if (c.id != null) c.id!: c,
        };
        _accountNames = {
          for (final a in accounts)
            if (a.id != null) a.id!: a.name,
        };
        _categoryNames = {
          for (final c in categories)
            if (c.id != null) c.id!: c.name,
        };
        _isLoading = false;
      });
    } catch (e) {
      print('加载记录失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ==================== 数据计算方法 ====================
  double _calculateMonthlyTotal(String type) {
    double total = 0;
    for (final record in _allRecords) {
      if (record.type == type) {
        total += record.amount;
      }
    }
    return total;
  }

  Map<String, List<ExpenseRecord>> _groupRecordsByDate() {
    final Map<String, List<ExpenseRecord>> grouped = {};

    for (final record in _allRecords) {
      final dateKey = _formatDate(record.date);
      if (!grouped.containsKey(dateKey)) {
        grouped[dateKey] = [];
      }
      grouped[dateKey]!.add(record);
    }

    return grouped;
  }

  Map<String, double> _calculateDailyTotals(List<ExpenseRecord> records) {
    double expenseTotal = 0;
    double incomeTotal = 0;

    for (final record in records) {
      if (record.type == 'expense') {
        expenseTotal += record.amount;
      } else {
        incomeTotal += record.amount;
      }
    }

    return {'expense': expenseTotal, 'income': incomeTotal};
  }

  // ==================== 格式转换方法 ====================
  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatDateForDisplay(String dateStr) {
    final date = DateTime.parse(dateStr);
    final today = DateTime.now();
    final yesterday = DateTime.now().subtract(const Duration(days: 1));

    if (date.year == today.year &&
        date.month == today.month &&
        date.day == today.day) {
      return '今天';
    } else if (date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day) {
      return '昨天';
    } else {
      return '${date.month}月${date.day}日 ${_getWeekday(date.weekday)}';
    }
  }

  String _getWeekday(int weekday) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return weekdays[weekday - 1];
  }

  // ==================== 预算管理方法 ====================
  Future<void> _showBudgetSettingDialog() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BudgetManagementPage(
          initialLedgerId: _selectedLedgerId,
          initialMonth: _selectedDate,
        ),
      ),
    );
    if (mounted) await _loadBudget();
  }

  // 日期分组标题
  Widget _buildDateHeader(String dateStr, List<ExpenseRecord> records) {
    final totals = _calculateDailyTotals(records);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _formatDateForDisplay(dateStr),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF777D87),
            ),
          ),
          Row(
            children: [
              if (totals['expense']! > 0)
                Text(
                  '支 ${totals['expense']!.toStringAsFixed(2)}',
                  style: TextStyle(color: Color(0xFF858B95), fontSize: 12),
                ),
              if (totals['expense']! > 0 && totals['income']! > 0)
                const SizedBox(width: 12),
              if (totals['income']! > 0)
                Text(
                  '收 ${totals['income']!.toStringAsFixed(2)}',
                  style: TextStyle(color: Color(0xFF858B95), fontSize: 12),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // 空状态界面
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.receipt_long, size: 60, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            '${_selectedDate.month}月还没有账单记录',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            '点击「记一笔」，记录你的第一笔收支',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // ==================== 主界面构建 ====================
  @override
  Widget build(BuildContext context) {
    final groupedRecords = _groupRecordsByDate();
    final sortedDates = groupedRecords.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final blue = scheme.primary;
    final headerForeground = dark ? scheme.onSurface : scheme.onPrimary;
    final headerButtonForeground = dark
        ? scheme.onSurfaceVariant
        : scheme.onPrimary;
    final headerButtonBackground = dark
        ? scheme.surfaceContainerHigh
        : scheme.onPrimary.withValues(alpha: .18);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Column(
        children: [
          // 蓝色顶部区域：标题、账本切换、月份收支概览
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? [scheme.surfaceContainerHigh, scheme.surface]
                    : [blue, Color.lerp(blue, Colors.black, .18)!],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 10, 18, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '记账本',
                            style: TextStyle(
                              color: headerForeground,
                              fontSize: 25,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        if (AppSettings.instance.budgetEnabled)
                          TextButton.icon(
                            onPressed: _showBudgetSettingDialog,
                            style: TextButton.styleFrom(
                              foregroundColor: headerButtonForeground,
                              backgroundColor: headerButtonBackground,
                              shape: const StadiumBorder(),
                            ),
                            icon: const Icon(
                              Icons.account_balance_wallet_outlined,
                              size: 19,
                            ),
                            label: const Text('预算'),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => _showLedgerDropdown(context),
                              style: TextButton.styleFrom(
                                foregroundColor: headerButtonForeground,
                                backgroundColor: headerButtonBackground,
                                minimumSize: const Size(0, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 15,
                                ),
                                shape: const StadiumBorder(),
                                textStyle: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.receipt_long_rounded,
                                    size: 19,
                                  ),
                                  const SizedBox(width: 7),
                                  Flexible(
                                    child: Text(
                                      _selectedLedgerName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  const Icon(
                                    Icons.keyboard_arrow_down,
                                    size: 18,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: () => _showMonthDropdown(context),
                          style: TextButton.styleFrom(
                            foregroundColor: headerButtonForeground,
                            minimumSize: const Size(0, 40),
                            padding: EdgeInsets.zero,
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                          child: Text(
                            '${_selectedDate.year}年${_selectedDate.month}月',
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          // 月度总览卡片向上贴近蓝色头部，形成参考图的层次
          Transform.translate(
            offset: const Offset(0, -1),
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.045),
                    blurRadius: 18,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 40,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '支出',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 7),
                            SizedBox(
                              height: 34,
                              child: FittedBox(
                                alignment: Alignment.centerLeft,
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '¥${_monthlyExpense.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    fontSize: 27,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 3,
                        height: 53,
                        decoration: BoxDecoration(
                          color: blue,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '收入',
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: AppSettings.instance.hideIncome
                                      ? '显示收入金额'
                                      : '隐藏收入金额',
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(40, 40),
                                    padding: const EdgeInsets.all(8),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  iconSize: 22,
                                  onPressed: () async {
                                    try {
                                      await AppSettings.instance.setHideIncome(
                                        !AppSettings.instance.hideIncome,
                                      );
                                    } catch (_) {
                                      if (mounted)
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('隐藏设置保存失败，请重试'),
                                          ),
                                        );
                                    }
                                  },
                                  icon: Icon(
                                    AppSettings.instance.hideIncome
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            SizedBox(
                              height: 34,
                              child: AppSettings.instance.hideIncome
                                  ? const SizedBox.expand()
                                  : FittedBox(
                                      alignment: Alignment.centerLeft,
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        '¥${_monthlyIncome.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                          fontSize: 27,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (AppSettings.instance.budgetEnabled) ...[
                    const SizedBox(height: 20),
                    if (_monthlyBudget <= 0)
                      TextButton.icon(
                        onPressed: _showBudgetSettingDialog,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('设置本月预算'),
                      )
                    else ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text(
                            '预算 ¥${_monthlyBudget.toStringAsFixed(2)}',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            _monthlyExpense > _monthlyBudget
                                ? '已超支 ¥${(_monthlyExpense - _monthlyBudget).toStringAsFixed(2)}'
                                : '剩余 ¥${(_monthlyBudget - _monthlyExpense).toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: _monthlyExpense > _monthlyBudget
                                  ? Theme.of(context).colorScheme.error
                                  : blue,
                            ),
                          ),
                          Text(
                            '已用 ${(_monthlyExpense / _monthlyBudget * 100).toStringAsFixed(0)}%',
                            style: TextStyle(fontSize: 13, color: blue),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: LinearProgressIndicator(
                          value: _budgetUsagePercent,
                          minHeight: 5,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _monthlyExpense > _monthlyBudget
                                ? Theme.of(context).colorScheme.error
                                : blue,
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          const RecurringDueBanner(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _allRecords.isEmpty
                ? _buildEmptyState()
                : RefreshIndicator(
                    onRefresh: _loadRecords,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                      itemCount: sortedDates.length,
                      itemBuilder: (context, index) {
                        final dateStr = sortedDates[index];
                        final records = groupedRecords[dateStr]!;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDateHeader(dateStr, records),
                              ...records.map(
                                (record) => ExpenseItem(
                                  record: record,
                                  categoryName:
                                      _categoryNames[record.categoryId],
                                  categoryIcon:
                                      _recordCategories[record.categoryId]
                                          ?.icon,
                                  categoryColor:
                                      _recordCategories[record.categoryId]
                                          ?.color,
                                  accountName:
                                      _accountNames[record.assetAccountId],
                                  ledgerName: _isSummaryLedger
                                      ? _ledgerNameFor(record.ledgerId)
                                      : null,
                                  onDelete: () => _deleteRecord(record.id!),
                                  onEdit: () => _editRecord(record),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: _buildEntryButtons(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  // ==================== 账本管理方法 ====================
  void _showLedgerDropdown(BuildContext context) {
    // 原有的账本选择代码...
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final dark = theme.brightness == Brightness.dark;
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '选择账本',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _ledgers.length,
                  itemBuilder: (context, index) {
                    final ledger = _ledgers[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: ledger.isDefault == 1
                            ? (dark ? scheme.primaryContainer : scheme.primary)
                            : scheme.surfaceContainerHigh,
                        child: Icon(
                          ledger.icon != null
                              ? IconData(
                                  int.parse(ledger.icon!),
                                  fontFamily: 'MaterialIcons',
                                )
                              : Icons.book,
                          color: ledger.isDefault == 1
                              ? (dark
                                    ? scheme.onPrimaryContainer
                                    : scheme.onPrimary)
                              : scheme.onSurfaceVariant,
                          size: 18,
                        ),
                      ),
                      title: Row(
                        children: [
                          Text(ledger.name, style: TextStyle(fontSize: 14)),
                          if (ledger.isDefault == 1) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).primaryColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '默认',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle:
                          ledger.isDefault != 1 &&
                              (ledger.desc?.trim().isNotEmpty ?? false)
                          ? Text(ledger.desc!)
                          : null,
                      trailing: _selectedLedgerId == ledger.id
                          ? Icon(
                              Icons.check,
                              color: Theme.of(context).primaryColor,
                            )
                          : null,
                      onTap: () async {
                        await _switchLedger(ledger.id!);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.settings, color: Colors.grey, size: 18),
                title: Text(
                  '管理账本',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showLedgerManagementDialog();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ==================== 其他方法（省略部分代码保持简洁）====================
  Future<void> _switchLedger(int ledgerId) async {
    if (_selectedLedgerId != ledgerId) {
      setState(() {
        _selectedLedgerId = ledgerId;
      });
      await LedgerSettingsManager.setCurrentLedgerId(ledgerId);
      await _loadBudget();
      await _loadRecords();
    }
  }

  Future<void> _showMonthDropdown(BuildContext context) async {
    final chosen = await showDialog<DateTime>(
      context: context,
      builder: (_) => MonthPickerDialog(selected: _selectedDate),
    );
    if (chosen == null || !mounted) return;
    final now = DateTime.now();
    await _switchMonth(
      (chosen.year - now.year) * 12 + chosen.month - now.month,
    );
  }

  Future<void> _switchMonth(int monthOffset) async {
    if (_currentMonthOffset != monthOffset) {
      setState(() {
        _currentMonthOffset = monthOffset;
      });
      await LedgerSettingsManager.setCurrentMonthOffset(monthOffset);
      await _loadBudget();
      await _loadRecords();
    }
  }

  Future<void> _deleteRecord(int id) async {
    try {
      await _dbHelper.deleteRecord(id);
      setState(() {
        _allRecords.removeWhere((record) => record.id == id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除成功'), duration: Duration(seconds: 2)),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('删除失败: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _editRecord(ExpenseRecord record) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) =>
            AddRecordPage(record: record, defaultLedgerId: _selectedLedgerId),
      ),
    );
    if (saved == true && mounted) await _loadRecords();
  }

  String? _ledgerNameFor(int id) {
    for (final ledger in _ledgers) {
      if (ledger.id == id) return ledger.name;
    }
    return null;
  }

  Future<void> _navigateToAddRecord(BuildContext context) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddRecordPage(defaultLedgerId: _selectedLedgerId),
      ),
    );
    if (saved == true && mounted) {
      await _loadRecords();
      if (mounted)
        ScaffoldMessenger.of(
          this.context,
        ).showSnackBar(const SnackBar(content: Text('记账成功')));
    }
  }

  Future<void> _reviewVoiceRecord(String text) async {
    try {
      final saved = await reviewVoiceRecord(
        context,
        words: text,
        defaultLedgerId: _selectedLedgerId,
      );
      if (saved && mounted) {
        await _loadRecords();
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('语音账单已保存')));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('账单准备未完成，识别文字已保留，请核对后重试。')));
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => VoiceRecordPage(
            defaultLedgerId: _selectedLedgerId,
            initialText: text,
          ),
        ),
      );
      if (saved == true && mounted) await _loadRecords();
    }
  }

  Future<void> _navigateToVoiceRecord({String initialText = ''}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => VoiceRecordPage(
          defaultLedgerId: _selectedLedgerId,
          initialText: initialText,
        ),
      ),
    );
    if (saved == true && mounted) {
      await _loadRecords();
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('语音账单已保存')));
    }
  }

  void _showLedgerManagementDialog() {
    // 原有的账本管理对话框代码...
    showDialog(
      context: context,
      builder: (context) => LedgerManagementDialog(
        ledgers: _ledgers,
        onLedgerAdded: () async {},
        onLedgerUpdated: () async {},
        onLedgerDeleted: () async {},
        userId: _currentUserId ?? 1,
        dbHelper: _dbHelper,
      ),
    );
  }
}
