import '../sync/sync_edit_guard.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../services/bill_csv_service.dart';
import '../services/bill_file_reader.dart';
import '../services/bill_category_classifier.dart';
import '../services/import_review_service.dart';
import '../services/platform_bill_service.dart';
import '../services/named_bill_service.dart';
import 'import_review_page.dart';
import 'platform_import_options_dialog.dart';

class DataImportExportPage extends StatefulWidget {
  const DataImportExportPage({super.key});
  @override
  State<DataImportExportPage> createState() => _DataImportExportPageState();
}

class _DataImportExportPageState extends State<DataImportExportPage> {
  @override
  void dispose() {
    _releaseSyncEdit();
    super.dispose();
  }

  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _db = DatabaseHelper();
  bool _busy = false;
  int? _pendingCount;
  String? _result;
  List<String> _errors = [];
  List<String> _skipped = [];
  @override
  void initState() { super.initState(); _loadPending(); }
  Future<void> _loadPending() async {
    try {
      final count = await ImportReviewService(_db).pendingCount();
      if (mounted) setState(() => _pendingCount = count);
    } catch (_) { if (mounted) setState(() => _pendingCount = null); }
  }
  Future<void> _openReviews() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ImportReviewPage()));
    if (mounted) await _loadPending();
  }
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _result = null; _errors = []; _skipped = []; });
    try { await action(); }
    catch (e) {
      if (mounted) setState(() => _result = e is FormatException ? e.message.toString() : '操作失败：$e');
    } finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _export() => _run(() async {
    final user = await _db.getCurrentUser();
    final ledgerIds = (await _db.getAllLedgers(userId: user.id)).map((l) => l.id).toSet();
    final records = (await _db.getAllRecords()).where((r) => ledgerIds.contains(r.ledgerId)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    if (!mounted) return;
    if (records.isEmpty) { setState(() => _result = '没有账单可以导出'); return; }
    final categoryNames = {for (final c in await _db.getAllCategories(userId: user.id)) c.id!: c.name};
    if (!mounted) return;
    final bytes = Uint8List.fromList(utf8.encode(BillCsvService(_db).encode(records,
        categoryNames: categoryNames)));
    final path = await FilePicker.platform.saveFile(dialogTitle: '选择保存位置并保存账单',
      fileName: '记账账单_${DateTime.now().millisecondsSinceEpoch}.csv',
      type: FileType.custom, allowedExtensions: ['csv'], bytes: bytes);
    if (path == null) { if (mounted) setState(() => _result = '已取消保存，可以再次选择位置并导出'); return; }
    if (!kIsWeb && !Platform.isAndroid && !Platform.isIOS) await File(path).writeAsBytes(bytes, flush: true);
    if (mounted) setState(() => _result = '导出成功，共${records.length}条账单\n保存位置：$path');
  });
  Future<void> _import() => _run(() async {
    // Android providers may label CSV as plain text. Avoid hiding these files.
    final picked = await FilePicker.platform.pickFiles(type: FileType.any,
      dialogTitle: '选择CSV或Excel账单', withData: true);
    if (picked == null) return;
    final file = picked.files.single;
    final bytes = file.bytes ?? (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) throw const FormatException('无法读取所选文件，请先保存到系统“下载”或“文件”目录');
    final tables = await compute(_readTables, (file.name, bytes.toList()));
    if (!mounted) return;
    BillTable? table = tables.first;
    if (tables.length > 1) {
      table = await showDialog<BillTable>(context: context, builder: (context) => SimpleDialog(
        title: const Text('选择账单工作表'), children: tables.map((t) => SimpleDialogOption(
          onPressed: () => Navigator.pop(context, t), child: Text('${t.sheet} · ${t.source}'))).toList()));
    }
    if (table == null || !mounted) return;
    final selected = table;
    BillImportPreview preview;
    if (selected.external) {
      final user = await _db.getCurrentUser();
      final ledgers = await _db.getAllLedgers(userId: user.id);
      final categories = await BillCategoryClassifier.ensureFallbacks(_db, user.id!);
      final accounts = await _db.getAllAssetAccounts(userId: user.id);
      if (!mounted) return;
      final options = await showDialog<PlatformImportOptions>(context: context, builder: (_) => PlatformImportOptionsDialog(
        source: selected.source, ledgers: ledgers, categories: categories, accounts: accounts));
      if (options == null || !mounted) return;
      if (selected.source == BillFileReader.namedSource) {
        preview = await NamedBillService(_db).preview(selected, fileName: file.name, ledgerId: options.ledgerId,
          accountId: options.accountId, expenseCategoryId: options.expenseCategoryId,
          incomeCategoryId: options.incomeCategoryId, autoClassify: options.autoClassify);
      } else {
        preview = await PlatformBillService(_db).preview(selected, fileName: file.name, ledgerId: options.ledgerId,
          accountId: options.accountId, expenseCategoryId: options.expenseCategoryId,
          incomeCategoryId: options.incomeCategoryId, autoClassify: options.autoClassify);
      }
    } else {
      preview = await BillCsvService(_db).previewRows([selected.headers, ...selected.rows]);
    }
    final previewUser = await _db.getCurrentUser();
    final categoryNames = {for (final c in await _db.getAllCategories(userId: previewUser.id)) c.id!: c.name,
      for (final c in preview.newCategories) c.id!: c.name};
    if (!mounted) return;
    setState(() {
      _errors = preview.errors; _skipped = preview.skipped;
      _result = '${selected.source}账单：新增${preview.records.length}条，更新已有订单${preview.refundUpdateCount}条，'
        '全额退款${preview.fullyRefundedCount}条，重复${preview.duplicates}条，'
        '待核对${preview.reviewItems.length}条，跳过${preview.skipped.length}条';
    });
    if (preview.records.isEmpty && preview.reviewItems.isEmpty && preview.refundPlans.isEmpty) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => Dialog(
      child: SizedBox(width: 520, height: MediaQuery.sizeOf(context).height * .75,
        child: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
          Text('确认导入', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Expanded(child: ListView(children: [
            Text(file.name), const SizedBox(height: 12),
            Text('新增账单 ${preview.records.length}条\n更新已有订单及退款依据 ${preview.refundUpdateCount}条\n'
              '其中全额退款 ${preview.fullyRefundedCount}条\n待核对 ${preview.reviewItems.length}条\n'
              '重复 ${preview.duplicates}条\n跳过 ${preview.skipped.length}条'),
            const SizedBox(height: 12),
            if (preview.newCategories.isNotEmpty) Text('确认后新增分类：${preview.newCategories.map((c) => c.name).join('、')}'),
            const Text('待核对记录会保存到本机，暂不计入统计。你可以稍后逐项确认实际金额。'),
            if (preview.records.isNotEmpty) ...[
              const Divider(height: 28), const Text('直接记账的交易'),
              ...preview.records.map((r) => ListTile(contentPadding: EdgeInsets.zero,
                title: Text(r.title?.isNotEmpty == true ? r.title! : '未命名账单'),
                subtitle: Text('${r.date.toIso8601String().substring(0, 10)} · ${r.type == 'income' ? '收入' : '支出'} · ${categoryNames[r.categoryId] ?? '分类已变化'}\n'
                  '${r.refundGrossCents == null ? '' : '原付款 ¥${(r.refundGrossCents! / 100).toStringAsFixed(2)} · 已退 ¥${((r.refundTotalCents ?? 0) / 100).toStringAsFixed(2)}\n'}${r.note ?? ''}'),
                trailing: Text('¥${r.amount.toStringAsFixed(2)}'))),
            ],
            if (preview.refundPlans.any((plan) => !plan.isNew)) ...[
              const Divider(height: 28), const Text('更新已有订单'),
              ...preview.refundPlans.where((plan) => !plan.isNew).map((plan) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(plan.record.title ?? '已有账单'),
                subtitle: Text('原付款 ¥${(plan.state.grossCents / 100).toStringAsFixed(2)} · '
                  '累计成功退款 ¥${(plan.state.refundedCents / 100).toStringAsFixed(2)}\n'
                  '净支出 ¥${(plan.expectedRecord!['amount'] as num).toStringAsFixed(2)} → '
                  '¥${plan.record.amount.toStringAsFixed(2)}${plan.fullyRefunded ? ' · 全额退款' : ''}'),
              )),
            ],
            if (preview.reviewItems.isNotEmpty) ...[
              const Divider(height: 28), const Text('保存供稍后核对的交易'),
              ...preview.reviewItems.map((r) => ListTile(contentPadding: EdgeInsets.zero,
                title: Text(r.candidate?.title ?? r.original['交易对方'] ?? r.source), subtitle: Text(r.reason))),
            ],
            if (preview.errors.isNotEmpty) ...[const Divider(), ...preview.errors.map(Text.new)],
            if (preview.skipped.isNotEmpty) ExpansionTile(tilePadding: EdgeInsets.zero,
              title: Text('查看跳过的${preview.skipped.length}条记录'), children: preview.skipped.map(Text.new).toList()),
          ])),
          const SizedBox(height: 16),
          Row(children: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            const SizedBox(width: 12), Expanded(child: FilledButton(onPressed: () => Navigator.pop(context, true),
              child: Text(preview.records.isEmpty && preview.refundPlans.isEmpty ? '保存待核对账单'
                : preview.reviewItems.isEmpty ? '确认导入及更新' : '导入并保存待核对')))]),
        ])),
      ),
    ));
    if (confirmed != true || !mounted) {
      if (mounted) setState(() => _result = '已取消导入，本次文件的账单和待核对记录均未保存');
      return;
    }
    final imported = await BillCsvService(_db).importPreview(preview);
    await _loadPending();
    if (mounted) setState(() => _result = '导入完成：新增${imported.inserted}条，更新${imported.updated}条，'
      '全额退款${imported.fullyRefunded}条，跳过${preview.skipped.length}条\n'
      '本机共有${_pendingCount ?? 0}条待核对账单。重复导入不会重复保存同一条核对记录。');
  });
  static List<BillTable> _readTables((String, List<int>) input) => BillFileReader.read(input.$1, input.$2);
  Widget _actionCard({required IconData icon, required String title, required String detail,
    required String label, required VoidCallback action}) => Card(child: Padding(
      padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium)]),
        const SizedBox(height: 10), Text(detail), const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : action, child: Text(label))),
      ])));
  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy, child: Scaffold(
    appBar: AppBar(title: const Text('账单导入导出')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: ListTile(leading: const Icon(Icons.fact_check_outlined), title: const Text('待核对账单'),
        subtitle: Text(_pendingCount == null ? '打开查看已保存的原始交易' : '$_pendingCount条 · 可以稍后逐项确认'),
        trailing: const Icon(Icons.chevron_right), enabled: !_busy, onTap: _openReviews)),
      _actionCard(icon: Icons.download_outlined, title: '导出账单',
        detail: '导出为CSV。接下来选择保存目录，再点击系统窗口的“保存”。',
        label: '选择位置并导出', action: _export),
      _actionCard(icon: Icons.upload_file_outlined, title: '导入账单',
        detail: '支持支付宝、微信、本软件，以及含类型、金额、日期、分类、标签、描述和账户的CSV或Excel（.xlsx）表格。',
        label: '浏览并选择账单', action: _import),
      const Padding(padding: EdgeInsets.all(12), child: Text('找不到微信账单？在系统文件选择窗口查看“最近”或“下载”；如果账单只在微信内部，请先从微信保存到手机“文件”或“下载”目录。')),
      if (_busy) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
      if (_result != null) Card(child: Padding(padding: const EdgeInsets.all(16), child: SelectableText(_result!))),
      if ((_pendingCount ?? 0) > 0) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
        child: OutlinedButton.icon(onPressed: _busy ? null : _openReviews, icon: const Icon(Icons.fact_check_outlined),
          label: const Text('逐项核对 / 稍后回来核对'))),
      if (_errors.isNotEmpty) ExpansionTile(title: Text('导入说明 ${_errors.length}项'),
        children: _errors.map((e) => ListTile(title: SelectableText(e))).toList()),
      if (_skipped.isNotEmpty) ExpansionTile(title: Text('跳过记录 ${_skipped.length}条'),
        children: _skipped.map((e) => ListTile(title: SelectableText(e))).toList()),
      const SizedBox(height: 24),
      const Text('• 明确的成功退款按原付款减累计退款计算净支出；全额退款保留零净额记录，不另记收入。\n'
        '• 退款关联缺失、金额含义不明确、未知状态或人工调整过的交易，保存到待核对列表。\n'
        '• 已关闭、未支付或普通不计收支项目不参与统计，导入结果可查看跳过说明。\n'
        '• 明确的投资相关支出与收入自动跳过，不计入日常收支；可在“跳过记录”中核对原因。\n'
        '• 默认自动分类，无法识别时归入其他支出或其他收入；也可以关闭自动分类，统一选择分类。\n'
        '• 保留原始表头和交易号；Excel中的交易号应使用文本格式，公式请粘贴为值。\n'
        '• 关联账户的导入账单会更新余额，补导历史账单可选择不关联账户；CSV仅包含账单，完整数据请用备份与恢复。'),
    ]),
  ));
}
