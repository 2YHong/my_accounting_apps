import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/expense_record.dart';
import '../services/bill_category_classifier.dart';
import '../services/voice_bill_parser.dart';
import 'add_record_page.dart';

/// Builds a draft using existing local categories/ledger, then reuses the
/// regular editor. No record is written until the user explicitly saves it.
Future<bool> reviewVoiceRecord(
  BuildContext context, {
  required String words,
  int? defaultLedgerId,
}) async {
  final recognizedText = words.trim();
  if (recognizedText.isEmpty) return false;
  final draft = VoiceBillParser.parse(recognizedText);
  final db = DatabaseHelper();
  final user = await db.getCurrentUser();
  final userId = user.id;
  if (userId == null) throw StateError('No local user');
  final categories = await BillCategoryClassifier.ensureFallbacks(db, userId);
  final category = BillCategoryClassifier.choose(
    categories: categories,
    type: draft.type,
    title: draft.title,
    description: recognizedText,
  );
  final ledgers = await db.getAllLedgers(userId: userId);
  if (ledgers.isEmpty || category?.id == null) {
    throw StateError('No ledger or category');
  }
  final preferred = ledgers
      .where((ledger) => ledger.id == defaultLedgerId)
      .toList();
  final defaults = ledgers.where((ledger) => ledger.isDefault == 1).toList();
  final ledger = preferred.isNotEmpty
      ? preferred.first
      : defaults.isNotEmpty
      ? defaults.first
      : ledgers.first;
  final record = ExpenseRecord(
    ledgerId: ledger.id!,
    type: draft.type,
    amount: draft.amount ?? 0,
    categoryId: category!.id!,
    date: draft.date,
    title: draft.title,
    userId: userId,
    note: '语音原文：$recognizedText',
  );
  if (!context.mounted) return false;
  return await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => AddRecordPage(
            initialRecord: record,
            initialHints: draft.hints,
            defaultLedgerId: ledger.id,
          ),
        ),
      ) ==
      true;
}
