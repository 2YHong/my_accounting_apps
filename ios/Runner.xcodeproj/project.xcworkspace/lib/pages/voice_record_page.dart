import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../services/voice_bill_parser.dart';
import '../services/voice_recognition_service.dart';
import 'voice_record_review.dart';

class VoiceRecordPage extends StatefulWidget {
  final int? defaultLedgerId;
  final String initialText;
  const VoiceRecordPage({
    super.key,
    this.defaultLedgerId,
    this.initialText = '',
  });
  @override
  State<VoiceRecordPage> createState() => _VoiceRecordPageState();
}

class _VoiceRecordPageState extends State<VoiceRecordPage>
    with WidgetsBindingObserver {
  final _releaseSyncEdit = SyncEditGuard.acquire();

  final _text = TextEditingController();
  final _voice = VoiceRecognitionService.instance;
  String _lastRecognized = '';
  bool _preparing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.text = widget.initialText;
    _lastRecognized = _voice.words;
    _voice.addListener(_voiceChanged);
    _text.addListener(_textChanged);
  }

  void _textChanged() {
    if (mounted) setState(() {});
  }

  void _voiceChanged() {
    if (!mounted) return;
    if (_voice.words != _lastRecognized) {
      _lastRecognized = _voice.words;
      if (_lastRecognized.isNotEmpty) {
        _text.value = TextEditingValue(
          text: _lastRecognized,
          selection: TextSelection.collapsed(offset: _lastRecognized.length),
        );
      }
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached)
      _voice.cancel();
  }

  @override
  void dispose() {
    _releaseSyncEdit();
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_voiceChanged);
    _voice.cancel();
    _text.removeListener(_textChanged);
    _text.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (_preparing ||
        _voice.starting ||
        _voice.initializing ||
        _voice.processing ||
        _text.text.trim().isEmpty)
      return;
    setState(() => _preparing = true);
    try {
      await _voice.stop();
      if (!mounted) return;
      final saved = await reviewVoiceRecord(
        context,
        words: _text.text.trim(),
        defaultLedgerId: widget.defaultLedgerId,
      );
      if (saved == true && mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('账单准备失败，请稍后重试')));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _text.text.trim().isNotEmpty;
    final draft = hasText ? VoiceBillParser.parse(_text.text) : null;
    final busy =
        _preparing ||
        _voice.starting ||
        _voice.initializing ||
        _voice.processing;
    return Scaffold(
      appBar: AppBar(title: const Text('语音记账')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('说一笔，核对后保存', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('例如：今天我买了两包牛奶，花了七元。'),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        FocusScope.of(context).unfocus();
                        if (_voice.listening) {
                          await _voice.stop();
                        } else {
                          _text.clear();
                          _lastRecognized = '';
                          await _voice.start();
                        }
                      },
                icon: Icon(
                  _voice.listening ? Icons.stop_rounded : Icons.mic_rounded,
                ),
                label: Text(
                  _voice.initializing
                      ? '正在加载中文模型…'
                      : _voice.processing
                      ? '正在识别…'
                      : _voice.starting
                      ? '准备中…'
                      : _voice.listening
                      ? '说完了'
                      : '开始说话',
                ),
              ),
              const SizedBox(height: 12),
              if (_voice.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _voice.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              TextField(
                controller: _text,
                enabled: !busy && !_voice.listening,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: '识别文字',
                  hintText: _voice.listening
                      ? '正在听，说完后点击“说完了”'
                      : '也可以直接输入一句话，或修正识别文字',
                ),
              ),
              const SizedBox(height: 16),
              if (draft != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          draft.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${draft.type == 'expense' ? '支出' : '收入'} · '
                          '${draft.amount == null ? '金额待填写' : '¥${draft.amount!.toStringAsFixed(2)}'}',
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${draft.date.year}年${draft.date.month}月${draft.date.day}日',
                        ),
                        ...draft.hints.map(
                          (hint) => Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(hint),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy || _voice.listening || !hasText
                    ? null
                    : _continue,
                child: Text(_preparing ? '正在准备…' : '核对账单'),
              ),
              const SizedBox(height: 12),
              Text(
                '使用软件内置的中文离线模型。允许麦克风后即可说话，每次最多 30 秒。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
