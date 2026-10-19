import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/voice_recognition_service.dart';
import '../sync/sync_edit_guard.dart';

/// Keeps the recording overlay on the same route, so a held pointer is not
/// cancelled by navigation. Only a finished recording opens the bill editor.
class VoiceEntryButton extends StatefulWidget {
  final Future<void> Function(String text) onRecognized;
  final Future<void> Function(String text) onTypeInstead;
  final VoiceRecognitionService? service;
  const VoiceEntryButton({
    super.key,
    required this.onRecognized,
    required this.onTypeInstead,
    this.service,
  });

  @override
  State<VoiceEntryButton> createState() => _VoiceEntryButtonState();
}

class _VoiceEntryButtonState extends State<VoiceEntryButton>
    with WidgetsBindingObserver {
  late final _voice = widget.service ?? VoiceRecognitionService.instance;
  OverlayEntry? _overlay;
  void Function()? _releaseEdit;
  bool _active = false;
  bool _holding = false;
  bool _cancelOnRelease = false;
  bool _settling = false;
  bool _heard = false;
  bool _observedStart = false;
  String _words = '';
  int _operation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voice.addListener(_voiceChanged);
  }

  bool get _idle =>
      !_voice.starting &&
      !_voice.initializing &&
      !_voice.listening &&
      !_voice.processing;

  void _redraw() {
    if (mounted) _overlay?.markNeedsBuild();
  }

  void _voiceChanged() {
    if (!mounted || !_active) return;
    if (!_idle) _observedStart = true;
    if (_observedStart) _words = _voice.words;
    if (_voice.listening && !_heard) {
      _heard = true;
      unawaited(HapticFeedback.lightImpact());
    }
    _redraw();
    // The existing service also stops automatically at its 30 second limit.
    if (_heard && _idle && !_settling && _voice.error == null) {
      final operation = _operation;
      scheduleMicrotask(() {
        if (mounted && _active && operation == _operation && !_settling) {
          unawaited(_finish());
        }
      });
    }
  }

  Future<void> _begin({required bool holding}) async {
    if (_active || _settling) return;
    final operation = ++_operation;
    _releaseEdit = SyncEditGuard.acquire();
    setState(() {
      _active = true;
      _holding = holding;
      _cancelOnRelease = false;
      _heard = false;
      _observedStart = false;
      _words = '';
    });
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
    await _voice.start();
    if (!mounted || !_active || operation != _operation) return;
    _redraw();
  }

  void _removeOverlay() {
    final entry = _overlay;
    _overlay = null;
    entry?.remove();
    entry?.dispose();
  }

  Future<void> _cancel() async {
    if (!_active) return;
    ++_operation;
    final release = _releaseEdit;
    _releaseEdit = null;
    setState(() {
      _active = false;
      _holding = false;
      _cancelOnRelease = false;
    });
    _removeOverlay();
    try {
      await _voice.cancel();
    } finally {
      release?.call();
    }
  }

  Future<void> _finish() async {
    if (!_active || _settling) return;
    final operation = _operation;
    _settling = true;
    _holding = false;
    _redraw();
    try {
      // Releasing before microphone/model readiness cancels startup. It must
      // never open the microphone later after the user's finger has gone.
      if (!_heard && _idle && _voice.error != null) {
        _redraw();
        return;
      }
      if (!_heard) {
        await _cancel();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('录音尚未开始，准备好后请重新说一次。')));
        }
        return;
      }
      await _voice.stop();
      if (!mounted || !_active || operation != _operation) return;
      _words = _voice.words.trim();
      if (_words.isEmpty || _voice.error != null) {
        _redraw();
        return;
      }
      final release = _releaseEdit;
      _releaseEdit = null;
      setState(() => _active = false);
      _removeOverlay();
      try {
        await widget.onRecognized(_words);
      } finally {
        release?.call();
      }
    } finally {
      _settling = false;
      if (mounted) {
        setState(() {});
        _redraw();
      }
    }
  }

  Future<void> _typeInstead() async {
    final text = _words;
    await _cancel();
    if (mounted) await widget.onTypeInstead(text);
  }

  void _move(LongPressMoveUpdateDetails details) {
    if (!_active || !_holding) return;
    final cancel = details.offsetFromOrigin.dy < -72;
    if (cancel != _cancelOnRelease) {
      _cancelOnRelease = cancel;
      _redraw();
    }
  }

  void _release(LongPressEndDetails _) {
    if (!_active || !_holding) return;
    if (_cancelOnRelease) {
      unawaited(_cancel());
    } else {
      unawaited(_finish());
    }
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final scheme = Theme.of(overlayContext).colorScheme;
    final preparing = _voice.starting || _voice.initializing;
    final failed = _idle && _voice.error != null;
    final title = _cancelOnRelease
        ? '松开取消'
        : preparing
        ? '正在准备麦克风和中文识别…'
        : _voice.processing || _settling
        ? '正在整理识别结果…'
        : _voice.listening
        ? '正在听'
        : '录音已结束';
    return Stack(
      children: [
        ModalBarrier(
          color: Colors.black54,
          dismissible: !_holding && !_settling,
          onDismiss: () => unawaited(_cancel()),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Material(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            _cancelOnRelease
                                ? Icons.close_rounded
                                : Icons.mic_rounded,
                            size: 40,
                            color: _cancelOnRelease
                                ? scheme.error
                                : scheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: Theme.of(
                              overlayContext,
                            ).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            preparing
                                ? '看到“正在听”并收到振动提示后再说话。'
                                : _holding
                                ? '松开结束，上滑取消'
                                : '说完点下方按钮，直接核对账单',
                            textAlign: TextAlign.center,
                          ),
                          if (preparing || _voice.processing || _settling) ...[
                            const SizedBox(height: 12),
                            const LinearProgressIndicator(),
                          ],
                          if (_words.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 130),
                              child: SingleChildScrollView(child: Text(_words)),
                            ),
                          ],
                          if (_voice.error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _voice.error!,
                              style: TextStyle(color: scheme.error),
                            ),
                          ],
                          if (!_holding) ...[
                            const SizedBox(height: 16),
                            if (failed)
                              OutlinedButton.icon(
                                onPressed: _settling
                                    ? null
                                    : () async {
                                        await _cancel();
                                        if (mounted)
                                          await _begin(holding: false);
                                      },
                                icon: const Icon(Icons.refresh),
                                label: const Text('重新说一次'),
                              )
                            else
                              FilledButton.icon(
                                onPressed: _voice.listening && !_settling
                                    ? _finish
                                    : null,
                                icon: const Icon(Icons.check_rounded),
                                label: const Text('说完了，核对账单'),
                              ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                TextButton(
                                  onPressed: _settling ? null : _typeInstead,
                                  child: const Text('改用文字输入'),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(_cancel()),
                                  child: const Text('取消'),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            '本机离线识别 · 一次说一笔 · 最长 30 秒',
                            textAlign: TextAlign.center,
                            style: Theme.of(overlayContext).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_cancel());
    }
  }

  @override
  void dispose() {
    ++_operation;
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_voiceChanged);
    _removeOverlay();
    if (_active) unawaited(_voice.cancel());
    _releaseEdit?.call();
    _releaseEdit = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop: !_active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _active) unawaited(_cancel());
      },
      child: Semantics(
        label: '语音记账：点一下或按住说话',
        button: true,
        child: GestureDetector(
          onLongPressStart: (_) => unawaited(_begin(holding: true)),
          onLongPressMoveUpdate: _move,
          onLongPressEnd: _release,
          onLongPressCancel: () {
            if (_holding) unawaited(_cancel());
          },
          child: FloatingActionButton(
            heroTag: 'home_voice_entry',
            // The FAB's default tooltip consumes long presses; semantics below
            // keeps the spoken label without stealing the recording gesture.
            onPressed: _settling
                ? null
                : () => unawaited(_begin(holding: false)),
            backgroundColor: dark
                ? scheme.surfaceContainerHigh
                : scheme.secondaryContainer,
            foregroundColor: dark
                ? scheme.onSurface
                : scheme.onSecondaryContainer,
            elevation: 4,
            shape: const CircleBorder(),
            child: const Icon(Icons.mic_rounded),
          ),
        ),
      ),
    );
  }
}
