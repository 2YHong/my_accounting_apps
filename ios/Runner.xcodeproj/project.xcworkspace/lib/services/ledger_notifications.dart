import 'package:flutter/foundation.dart';

/// Refreshes retained pages after either ledger management entry saves changes.
final ValueNotifier<int> ledgerDataRevision = ValueNotifier<int>(0);

void notifyLedgersChanged() {
  ledgerDataRevision.value++;
}
