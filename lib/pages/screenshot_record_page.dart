import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/screenshot_recognition.dart';
import '../services/screenshot_bill_parser.dart';
import '../services/bill_category_classifier.dart';
import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../sync/sync_edit_guard.dart';
import 'add_record_page.dart';

class ScreenshotRecordPage extends StatefulWidget {
  final int? defaultLedgerId;
  final Future<String?> Function()? recognize;
  const ScreenshotRecordPage({super.key, this.defaultLedgerId, this.recognize});
  @override
  State<ScreenshotRecordPage> createState() => _ScreenshotRecordPageState();
}

class _ScreenshotRecordPageState extends State<ScreenshotRecordPage> {
  final _text = TextEditingController();
  final _release = SyncEditGuard.acquire();
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pick();
    });
  }

  @override
  void dispose() {
    _release();
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final text =
          await (widget.recognize ??
              ScreenshotRecognition().pickAndRecognize)();
      if (!mounted) return;
      if (text == null) {
        if (_text.text.isEmpty) Navigator.pop(context);
        return;
      }
      _text.text = text;
      if (text.isEmpty) setState(() => _error = '没有识别到文字，请选择清晰的单笔账单详情截图。');
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PlatformException && e.code == 'image_too_large'
              ? '图片过长或过大，请裁剪为单笔账单详情后重试。'
              : '截图读取或识别失败，请重新选择 PNG、JPG 或 WebP 图片。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _review() async {
    if (_busy || _text.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final draft = ScreenshotBillParser.parse(_text.text);
      final db = DatabaseHelper(),
          user = await DatabaseHelper().getCurrentUser();
      final categories = await BillCategoryClassifier.ensureFallbacks(
        db,
        user.id!,
      );
      final category = BillCategoryClassifier.choose(
        categories: categories,
        type: draft.type,
        title: draft.title,
        description: _text.text,
      );
      final ledgers = await db.getAllLedgers(userId: user.id!);
      final ledger =
          ledgers.where((v) => v.id == widget.defaultLedgerId).firstOrNull ??
          ledgers.where((v) => v.isDefault == 1).firstOrNull ??
          ledgers.firstOrNull;
      if (ledger?.id == null || category?.id == null) {
        throw StateError('missing category');
      }
      final record = ExpenseRecord(
        ledgerId: ledger!.id!,
        type: draft.type,
        amount: (draft.amountCents ?? 0) / 100,
        categoryId: category!.id!,
        date: draft.date,
        title: draft.title,
        userId: user.id,
        note: '截图识别原文：\n${_text.text}',
      );
      if (!mounted) return;
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => AddRecordPage(
            initialRecord: record,
            initialHints: draft.hints,
            defaultLedgerId: ledger.id,
          ),
        ),
      );
      if (saved == true && mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = '账单草稿暂未生成，识别文字已保留，请重试或手动记一笔。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('截图记账')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('选择一张单笔账单详情截图，中英文均可。本机识别，不上传截图；核对后才保存账单。'),
          const SizedBox(height: 16),
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            const Text('正在读取和识别截图…'),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.image_outlined),
            label: const Text('选择截图'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 8,
            maxLines: 16,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '识别文字（可修改）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _review,
            child: const Text('核对账单'),
          ),
          const SizedBox(height: 8),
          const Text('适合微信、支付宝等单笔账单截图。多笔列表、外币换算和退款分摊请手动核对。'),
        ],
      ),
    ),
  );
}
