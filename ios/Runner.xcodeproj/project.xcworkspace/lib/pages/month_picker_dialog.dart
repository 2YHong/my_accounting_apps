import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MonthPickerDialog extends StatefulWidget {
  final DateTime selected;
  const MonthPickerDialog({super.key, required this.selected});

  @override
  State<MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<MonthPickerDialog> {
  late int _year;

  @override
  void initState() {
    super.initState();
    _year = widget.selected.year.clamp(1900, 2200).toInt();
  }

  Future<void> _chooseYear() async {
    final chosen = await showDialog<int>(context: context,
      builder: (_) => _YearSelectionDialog(selectedYear: _year));
    if (chosen != null && mounted) setState(() => _year = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 380,
          maxHeight: MediaQuery.sizeOf(context).height * .85),
        child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: Text('选择月份', style: Theme.of(context).textTheme.titleLarge)),
              IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              IconButton(tooltip: '上一年',
                onPressed: _year > 1900 ? () => setState(() => _year--) : null,
                icon: const Icon(Icons.chevron_left)),
              Expanded(child: TextButton.icon(
                onPressed: _chooseYear,
                icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                iconAlignment: IconAlignment.end,
                label: Text('$_year年', maxLines: 1,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              )),
              IconButton(tooltip: '下一年',
                onPressed: _year < 2200 ? () => setState(() => _year++) : null,
                icon: const Icon(Icons.chevron_right)),
            ]),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, mainAxisExtent: 52,
                mainAxisSpacing: 10, crossAxisSpacing: 10),
              itemCount: 12,
              itemBuilder: (context, index) {
                final month = index + 1;
                final selected = _year == widget.selected.year && month == widget.selected.month;
                return OutlinedButton(
                  onPressed: () => Navigator.pop(context, DateTime(_year, month)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    foregroundColor: selected ? scheme.onPrimary : scheme.onSurface,
                    backgroundColor: selected ? scheme.primary : scheme.surface,
                    side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: FittedBox(fit: BoxFit.scaleDown,
                    child: Text('$month月', maxLines: 1, softWrap: false,
                      style: const TextStyle(fontSize: 15))),
                );
              },
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                final now = DateTime.now();
                Navigator.pop(context, DateTime(now.year, now.month));
              },
              icon: const Icon(Icons.today_outlined, size: 18),
              label: const Text('回到本月'),
            ),
          ]),
        )),
      ),
    );
  }
}

class _YearSelectionDialog extends StatefulWidget {
  final int selectedYear;
  const _YearSelectionDialog({required this.selectedYear});

  @override
  State<_YearSelectionDialog> createState() => _YearSelectionDialogState();
}

class _YearSelectionDialogState extends State<_YearSelectionDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.selectedYear.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _selectEnteredYear() {
    final year = int.tryParse(_controller.text.trim());
    if (year == null || year < 1900 || year > 2200) {
      setState(() => _error = '请输入 1900 至 2200 年');
      return;
    }
    Navigator.pop(context, year);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 380,
        maxHeight: MediaQuery.sizeOf(context).height * .85),
      child: SingleChildScrollView(child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text('选择年份', style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _selectEnteredYear(),
            onChanged: (_) { if (_error != null) setState(() => _error = null); },
            decoration: InputDecoration(labelText: '年份', errorText: _error,
              suffixIcon: IconButton(tooltip: '使用此年份', onPressed: _selectEnteredYear,
                icon: const Icon(Icons.check))),
          ),
          const SizedBox(height: 8),
          SizedBox(height: 260, child: YearPicker(
            firstDate: DateTime(1900), lastDate: DateTime(2200, 12, 31),
            selectedDate: DateTime(widget.selectedYear),
            onChanged: (date) => Navigator.pop(context, date.year),
          )),
        ]),
      )),
    ),
  );
}
