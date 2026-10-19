import 'package:flutter/material.dart';
import '../models/expense_record.dart';
import 'category_style.dart';

class ExpenseItem extends StatelessWidget {
  final ExpenseRecord record;
  final String? categoryName;
  final String? categoryIcon;
  final String? categoryColor;
  final String? ledgerName;
  final String? accountName;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const ExpenseItem({
    super.key,
    required this.record,
    this.categoryName,
    this.categoryIcon,
    this.categoryColor,
    this.ledgerName,
    this.accountName,
    required this.onDelete,
    required this.onEdit,
  });

  // 判断是否为支出
  bool get _isExpense => record.type == 'expense';

  // 根据收入、支出返回颜色
  Color get _typeColor =>
      _isExpense ? const Color(0xFFFF7043) : const Color(0xFF26A69A);

  // 根据类型返回图标
  IconData get _typeIcon =>
      _isExpense ? Icons.shopping_bag_outlined : Icons.account_balance_wallet_outlined;

  // 格式化金额
  String get _formattedAmount {
    final prefix = _isExpense ? '-' : '+';
    return '$prefix¥${record.amount.abs().toStringAsFixed(2)}';
  }

  // 格式化日期时间
  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');

    return '$month-$day $hour:$minute';
  }

  // 确认删除
  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text('删除这笔账单？'),
        content: const Text('删除后将无法直接恢复，请确认操作。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              '取消',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              '确认删除',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  // 处理删除
  Future<void> _deleteWithConfirmation(BuildContext context) async {
    final confirmed = await _confirmDelete(context);

    if (confirmed && context.mounted) {
      onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = record.note?.trim() ?? '';
    final title = record.displayTitle(categoryName);
    final subtitle = [
      if ((record.title?.trim().isNotEmpty ?? false) && categoryName != null) categoryName!,
      if (accountName != null) accountName!,
      if (ledgerName != null) ledgerName!,
      if (record.refundTotalCents != null && record.refundTotalCents! > 0)
        record.refundGrossCents == record.refundTotalCents ? '已全额退款 · 净额为0'
          : '已退¥${(record.refundTotalCents! / 100).toStringAsFixed(2)} · 显示净额',
      if (note.isNotEmpty) note,
      _formatDate(record.date),
    ].join(' · ');
    final iconColor = Theme.of(context).colorScheme.primary;

    return Dismissible(
      key: ValueKey(record.id),
      direction: DismissDirection.endToStart,

      // 左滑时显示删除背景
      background: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete_outline, color: Colors.white, size: 28),
            SizedBox(height: 4),
            Text(
              '删除',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),

      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => onDelete(),

      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 2,
        ),
        elevation: 0,
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFF0F0F0)),
        ),
        clipBehavior: Clip.antiAlias,

        child: InkWell(
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            child: Row(
              children: [
                // 左侧分类图标
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    categoryIcons[categoryIconKey(categoryName ?? '', categoryIcon)] ?? _typeIcon,
                    color: iconColor,
                    size: 20,
                  ),
                ),

                const SizedBox(width: 10),

                // 中间备注、分类、时间
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // 右侧金额、更多操作
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(_formattedAmount, maxLines: 1,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _typeColor)),
                      ),
                    ),
                    const SizedBox(width: 2),
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 130,
                      ),
                      iconSize: 20,
                      icon: const Icon(
                        Icons.more_horiz,
                        color: Color(0xFF999999),
                      ),
                      onSelected: (value) {
                        if (value == 'edit') {
                          onEdit();
                        } else if (value == 'delete') {
                          _deleteWithConfirmation(context);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem<String>(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: Colors.black54,
                              ),
                              SizedBox(width: 10),
                              Text('编辑账单'),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Colors.red,
                              ),
                              SizedBox(width: 10),
                              Text(
                                '删除账单',
                                style: TextStyle(color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
