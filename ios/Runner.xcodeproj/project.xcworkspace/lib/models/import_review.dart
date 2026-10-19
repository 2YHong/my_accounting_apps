import 'dart:convert';
import 'expense_record.dart';

class ImportReviewDraft {
  final int userId;
  final String source;
  final String rowKey;
  final String reason;
  final String fileName;
  final String? importKey;
  final Map<String, String> original;
  final ExpenseRecord? candidate;
  final int ledgerId;
  final int? accountId;
  final int expenseCategoryId;
  final int incomeCategoryId;
  const ImportReviewDraft({required this.userId, required this.source, required this.rowKey,
    required this.reason, required this.fileName, required this.original, this.candidate, this.importKey,
    required this.ledgerId, this.accountId, required this.expenseCategoryId, required this.incomeCategoryId});
  Map<String, Object?> toMap() => {
    'user_id': userId, 'source': source, 'row_key': rowKey, 'reason': reason,
    'status': 'pending', 'created_at': DateTime.now().toIso8601String(),
    'payload': jsonEncode({'file_name': fileName, if (importKey != null) 'import_key': importKey,
      'original': original, 'candidate': candidate?.toMap(),
      'ledger_id': ledgerId, 'account_id': accountId,
      'expense_category_id': expenseCategoryId, 'income_category_id': incomeCategoryId}),
  };
}

class ImportReviewItem {
  final int id;
  final String source;
  final String reason;
  final Map<String, dynamic> payload;
  ImportReviewItem.fromMap(Map<String, Object?> map)
    : id = map['id'] as int, source = map['source'] as String, reason = map['reason'] as String,
      payload = jsonDecode(map['payload'] as String) as Map<String, dynamic>;
  Map<String, String> get original => Map<String, String>.from(payload['original'] as Map);
  ExpenseRecord? get candidate => payload['candidate'] == null ? null
    : ExpenseRecord.fromMap(Map<String, dynamic>.from(payload['candidate'] as Map));
}
