import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../models/category.dart';
import '../models/ledger.dart';
import '../models/asset_account.dart';
import '../models/settings_manager.dart';
import '../models/statistics_summary.dart';
import '../components/category_style.dart';
import 'add_record_page.dart';

class StatisticsPage extends StatefulWidget {
  final int refreshToken;
  const StatisticsPage({super.key, this.refreshToken = 0});
  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  static const _expenseColor = Color(0xFFE76B4A);
  static const _incomeColor = Color(0xFF169B83);
  Color get _blue => Theme.of(context).colorScheme.primary;
  List<Color> get _palette => [_blue, _incomeColor, Color(0xFFF29D38), Color(0xFF8B69CE), Color(0xFFDF6B9B), Color(0xFF8D98A8)];
  final _db = DatabaseHelper();
  StatisticsPeriod _period = StatisticsPeriod.month;
  StatisticsRange _range = StatisticsRange.forPeriod(StatisticsPeriod.month, DateTime.now());
  StatisticsSummary? _summary;

  List<Ledger> _ledgers = [];
  Map<int, Category> _categories = {};
  Map<int, String> _accounts = {};
  int? _ledgerId;
  int? _homeOffset;
  int _loadSerial = 0;
  bool _loading = true;
  String? _error;
  String _categoryType = 'expense';
  String _trendMode = 'both';

  @override
  void initState() { super.initState(); _load(syncHome: true); }

  @override
  void didUpdateWidget(covariant StatisticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) _load(syncHome: true);
  }

  Future<void> _load({bool syncHome = false}) async {
    final serial = ++_loadSerial;
    setState(() { _loading = true; _error = null; });
    var range = _range;
    var period = _period;
    var desiredLedger = _ledgerId;
    var homeOffset = _homeOffset;
    try {
      final user = await _db.getCurrentUser();
      final lists = await Future.wait<dynamic>([
        _db.getAllLedgers(userId: user.id),
        _db.getAllCategories(userId: user.id),
        _db.getAllAssetAccounts(userId: user.id),
      ]);
      final ledgers = lists[0] as List<Ledger>;
      final categories = lists[1] as List<Category>;
      final accounts = lists[2] as List<AssetAccount>;
      if (syncHome) {
        desiredLedger = await LedgerSettingsManager.getCurrentLedgerId();
        final savedOffset = await LedgerSettingsManager.getCurrentMonthOffset();
        homeOffset = savedOffset;
        if (_homeOffset != homeOffset) {
          final now = DateTime.now();
          range = StatisticsRange.forPeriod(StatisticsPeriod.month, DateTime(now.year, now.month + savedOffset, 1));
          period = StatisticsPeriod.month;
        }
      }
      if (ledgers.isEmpty) throw StateError('No ledger');
      final selected = ledgers.firstWhere((l) => l.id == desiredLedger, orElse: () => ledgers.first);
      final queryLedger = selected.isDefault == 1 ? null : selected.id;
      final records = await _db.getRecordsByDateRange(range.start, range.end, ledgerId: queryLedger, userId: user.id);

      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _range = range; _period = period; _ledgerId = selected.id; _homeOffset = homeOffset;
        _ledgers = ledgers;
        _categories = {for (final c in categories) if (c.id != null) c.id!: c};
        _accounts = {for (final a in accounts) if (a.id != null) a.id!: a.name};
        _summary = StatisticsSummary(range, records);
        _loading = false;
      });
    } catch (_) {
      if (mounted && serial == _loadSerial) setState(() {
        _loading = false; _error = '统计数据加载失败，请重试';
      });
    }
  }

  String _money(double amount) => '¥${amount.toStringAsFixed(2)}';
  String _date(DateTime date) => '${date.year}/${date.month}/${date.day}';
  String get _rangeText => switch (_period) {
    StatisticsPeriod.month => '${_range.start.year}年${_range.start.month}月',
    StatisticsPeriod.year => '${_range.start.year}年',
    _ => '${_date(_range.start)} — ${_date(_range.end)}',
  };


  Future<void> _selectPeriod(StatisticsPeriod period) async {
    if (period == StatisticsPeriod.custom) { await _pickRange(custom: true); return; }
    final now = DateTime.now();
    final anchor = _range.contains(now) ? now : _range.start;
    setState(() { _period = period; _range = StatisticsRange.forPeriod(period, anchor); });
    await _load();
  }

  void _move(int direction) {
    setState(() => _range = _range.shift(_period, direction));
    _load();
  }

  Future<void> _pickRange({bool custom = false}) async {
    if (custom || _period == StatisticsPeriod.custom) {
      final picked = await showDateRangePicker(context: context,
        firstDate: DateTime(1900), lastDate: DateTime(2200),
        initialDateRange: DateTimeRange(start: _range.start, end: _range.end));
      if (picked == null || !mounted) return;
      setState(() { _period = StatisticsPeriod.custom; _range = StatisticsRange(picked.start, picked.end); });
    } else {
      final picked = await showDatePicker(context: context, initialDate: _range.start,
        firstDate: DateTime(1900), lastDate: DateTime(2200),
        helpText: _period == StatisticsPeriod.year ? '选择目标年份中的任意一天' : '选择目标月份中的任意一天');
      if (picked == null || !mounted) return;
      setState(() => _range = StatisticsRange.forPeriod(_period, picked));
    }
    await _load();
  }

  Widget _card(Widget child) => Card(margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(18), child: child));

  Widget _filters() => _card(Column(children: [
    if (_ledgers.isNotEmpty) DropdownButtonFormField<int>(
      key: ValueKey('ledger-$_ledgerId'), initialValue: _ledgerId, isExpanded: true,
      decoration: const InputDecoration(labelText: '统计账本', prefixIcon: Icon(Icons.receipt_long_outlined)),
      items: _ledgers.map((l) => DropdownMenuItem(value: l.id,
        child: Text(l.isDefault == 1 ? '${l.name} · 全部汇总' : l.name, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (id) { setState(() => _ledgerId = id); _load(); }),
    const SizedBox(height: 12),
    Wrap(spacing: 8, runSpacing: 4, children: [StatisticsPeriod.month, StatisticsPeriod.year].map((period) => ChoiceChip(
      label: Text(switch (period) {
        StatisticsPeriod.week => '周', StatisticsPeriod.month => '月',
        StatisticsPeriod.year => '年', StatisticsPeriod.custom => '自定义',
      }), selected: _period == period, onSelected: (_) => _selectPeriod(period))).toList()),
    const SizedBox(height: 6),
    Row(children: [
      IconButton(tooltip: '上一时段', onPressed: () => _move(-1), icon: const Icon(Icons.chevron_left)),
      Expanded(child: TextButton(onPressed: _pickRange,
        child: Text(_rangeText, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)))),
      IconButton(tooltip: '下一时段', onPressed: () => _move(1), icon: const Icon(Icons.chevron_right)),
    ]),
  ]));

  Widget _metric(String label, double value, Color color) => Expanded(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
      const SizedBox(height: 8),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
        child: Text(_money(value), style: TextStyle(fontSize: 24, color: color))),
    ]));

  Widget _overview() {
    final report = _summary!;
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('收支概览', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      const SizedBox(height: 18),
      Row(children: [_metric('支出', report.expense, _expenseColor),
        const SizedBox(width: 24), _metric('收入', report.income, _incomeColor)]),
      if (report.records.isEmpty) const Padding(padding: EdgeInsets.only(top: 16),
        child: Text('所选时段暂无账单', style: TextStyle(color: Colors.grey))),
    ]));
  }

  String _trendLabel(TrendPoint point, String unit) => unit == 'year' ? '${point.date.year}'
    : unit == 'month' ? '${point.date.month}月' : '${point.date.month}/${point.date.day}';
  String _axisMoney(double value) => value.abs() >= 10000 ? '${(value / 10000).toStringAsFixed(1)}万'
    : value.abs() >= 1000 ? '${(value / 1000).toStringAsFixed(1)}千' : value.toStringAsFixed(0);

  Widget _trend() {
    final points = _summary!.trend();
    final showExpense = _trendMode != 'income';
    final showIncome = _trendMode != 'expense';
    final maximum = points.fold<double>(0, (value, p) => math.max(value,
      math.max(showExpense ? p.expense : 0.0, showIncome ? p.income : 0.0)));
    final maxY = maximum > 0 ? maximum * 1.25 : 10.0;
    final labelStep = math.max(1, ((points.length - 1) / 4).ceil()).toDouble();
    final unit = _summary!.trendUnit;
    LineChartBarData series(bool income) => LineChartBarData(
      spots: [for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), income ? points[i].income : points[i].expense)],
      color: income ? _incomeColor : _expenseColor, barWidth: 2.5,
      isCurved: false, dotData: FlDotData(show: points.length <= 14),
      belowBarData: BarAreaData(show: true, color: (income ? _incomeColor : _expenseColor).withValues(alpha: .06)),
    );
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('收支趋势', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: ['both', 'expense', 'income'].map((mode) => ChoiceChip(
        label: Text(mode == 'both' ? '收支' : mode == 'expense' ? '支出' : '收入'),
        selected: _trendMode == mode, onSelected: (_) => setState(() => _trendMode = mode))).toList()),
      const SizedBox(height: 8),
      Text('${unit == 'day' ? '按日' : unit == 'month' ? '按月' : '按年'}展示 · 空白时段按零计 · 点击图表查看金额',
        style: const TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: 20),
      SizedBox(height: 230, child: LineChart(LineChartData(
        minX: 0, maxX: math.max(1, points.length - 1).toDouble(), minY: 0, maxY: maxY,
        gridData: FlGridData(drawVerticalLine: false, horizontalInterval: maxY / 4),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 42, interval: maxY / 4,
            getTitlesWidget: (value, meta) => Text(_axisMoney(value), style: const TextStyle(fontSize: 10, color: Colors.grey)))),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 28, interval: labelStep,
            getTitlesWidget: (value, meta) {
              final index = value.round();
              if ((value - index).abs() > .01 || index < 0 || index >= points.length) return const SizedBox.shrink();
              return Padding(padding: const EdgeInsets.only(top: 7), child: Text(_trendLabel(points[index], unit),
                style: const TextStyle(fontSize: 10, color: Colors.grey)));
            })),
        ),
        lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(
          tooltipBgColor: const Color(0xFF303A48), fitInsideHorizontally: true, fitInsideVertically: true,
          getTooltipItems: (spots) => spots.map((spot) {
            final index = spot.x.round().clamp(0, points.length - 1).toInt();
            final income = spot.bar.color == _incomeColor;
            return LineTooltipItem('${_trendLabel(points[index], unit)} ${income ? '收入' : '支出'}\n${_money(spot.y)}',
              const TextStyle(color: Colors.white, fontSize: 12));
          }).toList(),
        )),
        lineBarsData: [if (showExpense) series(false), if (showIncome) series(true)],
      ))),
      const SizedBox(height: 8),
      Wrap(spacing: 16, children: [
        if (showExpense) const Text('● 支出', style: TextStyle(color: _expenseColor, fontSize: 12)),
        if (showIncome) const Text('● 收入', style: TextStyle(color: _incomeColor, fontSize: 12)),
      ]),
    ]));
  }

  Future<void> _details(List<CategoryTotal> totals, String title) async {
    final records = totals.expand((t) => t.records).toList()..sort((a, b) => b.date.compareTo(a.date));
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _StatisticsRecordsPage(
      title: title, records: records, categories: _categories, accounts: _accounts,
      ledgers: {for (final l in _ledgers) if (l.id != null) l.id!: l.name})));
    if (changed == true && mounted) await _load();
  }

  Widget _breakdown() {
    final totals = _summary!.categories(_categoryType);
    final totalCents = _categoryType == 'expense' ? _summary!.expenseCents : _summary!.incomeCents;
    final segments = <({String name, int cents, List<CategoryTotal> categories})>[];
    for (final entry in totals.take(5)) {
      segments.add((name: _categories[entry.categoryId]?.name ?? '未分类', cents: entry.cents, categories: [entry]));
    }
    if (totals.length > 5) {
      final rest = totals.skip(5).toList();
      segments.add((name: '其他分类', cents: rest.fold<int>(0, (sum, c) => sum + c.cents), categories: rest));
    }
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('收支分类', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      SegmentedButton<String>(segments: const [
        ButtonSegment(value: 'expense', label: Text('支出分类')), ButtonSegment(value: 'income', label: Text('收入分类')),
      ], selected: {_categoryType}, onSelectionChanged: (selection) => setState(() => _categoryType = selection.first)),
      const SizedBox(height: 18),
      if (totals.isEmpty || totalCents <= 0) const Padding(padding: EdgeInsets.symmetric(vertical: 30),
        child: Center(child: Text('这个时段暂无对应收支记录', style: TextStyle(color: Colors.grey))))
      else ...[
        SizedBox(height: 200, child: Stack(alignment: Alignment.center, children: [
          PieChart(PieChartData(centerSpaceRadius: 62, sectionsSpace: 3,
            pieTouchData: PieTouchData(touchCallback: (event, response) {
              if (event is! FlTapUpEvent) return;
              final index = response?.touchedSection?.touchedSectionIndex ?? -1;
              if (index >= 0 && index < segments.length) _details(segments[index].categories, segments[index].name);
            }),
            sections: [for (var i = 0; i < segments.length; i++) PieChartSectionData(
              value: segments[i].cents.toDouble(), color: _palette[i], radius: 32, showTitle: false)],
          )),
          IgnorePointer(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_categoryType == 'expense' ? '总支出' : '总收入', style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 5),
            SizedBox(width: 110, child: FittedBox(fit: BoxFit.scaleDown,
              child: Text(_money(totalCents / 100), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)))),
          ])),
        ])),
        const SizedBox(height: 12),
        Wrap(spacing: 14, runSpacing: 8, children: [for (var i = 0; i < segments.length; i++)
          InkWell(onTap: () => _details(segments[i].categories, segments[i].name),
            child: Text('● ${segments[i].name} ${(segments[i].cents / totalCents * 100).toStringAsFixed(1)}%',
              style: TextStyle(fontSize: 12, color: _palette[i])))],
        ),
        const Divider(height: 28),
        const Text('全部分类排行 · 点击查看明细', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 8),
        ...totals.asMap().entries.map((item) {
          final entry = item.value;
          final category = _categories[entry.categoryId];
          final fraction = entry.cents / totalCents;
          final color = _palette[item.key % _palette.length];
          return InkWell(onTap: () => _details([entry], category?.name ?? '未分类'), child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10), child: Column(children: [
              Row(children: [
                SizedBox(width: 24, child: Text('${item.key + 1}', style: const TextStyle(color: Colors.grey, fontSize: 12))),
                Icon(categoryIcons[categoryIconKey(category?.name ?? '', category?.icon)], color: color, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(category?.name ?? '未分类', maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text(_money(entry.amount), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(width: 6), const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
              ]),
              const SizedBox(height: 7),
              Padding(padding: const EdgeInsets.only(left: 24), child: Row(children: [
                Expanded(child: LinearProgressIndicator(value: fraction.clamp(0.0, 1.0).toDouble(), minHeight: 4,
                  color: color, backgroundColor: color.withValues(alpha: .08))),
                const SizedBox(width: 12), Text('${entry.count}笔 · ${(fraction * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ])),
            ]),
          ));
        }),
      ],
    ]));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('统计'), actions: [
      IconButton(tooltip: '刷新统计', onPressed: () => _load(), icon: const Icon(Icons.refresh)),
    ]),
    body: RefreshIndicator(onRefresh: () => _load(), child: LayoutBuilder(builder: (context, constraints) =>
      SingleChildScrollView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16),
        child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _filters(), const SizedBox(height: 14),
            if (_loading) const Padding(padding: EdgeInsets.all(60), child: Center(child: CircularProgressIndicator()))
            else if (_error != null) _card(Column(children: [Text(_error!),
              TextButton(onPressed: () => _load(syncHome: _ledgers.isEmpty), child: const Text('重新加载'))]))
            else if (_summary != null) ...[
              _overview(), const SizedBox(height: 14),
              _breakdown(), const SizedBox(height: 14), _trend(),

            ],
            const SizedBox(height: 24),
          ]),
        )),
      ),
    )),
  );
}

class _StatisticsRecordsPage extends StatelessWidget {
  final String title;
  final List<ExpenseRecord> records;
  final Map<int, Category> categories;
  final Map<int, String> accounts;
  final Map<int, String> ledgers;
  const _StatisticsRecordsPage({required this.title, required this.records,
    required this.categories, required this.accounts, required this.ledgers});

  Future<void> _edit(BuildContext context, ExpenseRecord record) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => AddRecordPage(record: record)));
    if (saved == true && context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final total = records.fold<int>(0, (sum, r) => sum + (r.amount * 100).round()) / 100;
    return Scaffold(appBar: AppBar(title: Text('$title · ${records.length}笔')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(20), child: Text('合计 ¥${total.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
        Expanded(child: ListView.separated(itemCount: records.length,
          separatorBuilder: (_, index) => const Divider(height: 1), itemBuilder: (context, index) {
            final record = records[index];
            final category = categories[record.categoryId];
            final note = record.note?.trim() ?? '';
            final subtitle = [
              '${record.date.year}/${record.date.month}/${record.date.day}',
              if (ledgers[record.ledgerId] != null) ledgers[record.ledgerId]!,
              if (accounts[record.assetAccountId] != null) accounts[record.assetAccountId]!,
              if (note.isNotEmpty) note,
            ].join(' · ');
            return ListTile(onTap: () => _edit(context, record),
              leading: Icon(categoryIcons[categoryIconKey(category?.name ?? '', category?.icon)],
                color: categoryDisplayColor(category?.color, income: record.type == 'income')),
              title: Text(record.displayTitle(category?.name), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: Text('${record.type == 'expense' ? '-' : '+'}¥${record.amount.toStringAsFixed(2)}',
                style: TextStyle(fontWeight: FontWeight.w600,
                  color: record.type == 'expense' ? const Color(0xFFE76B4A) : const Color(0xFF169B83))));
          })),
      ]));
  }
}
