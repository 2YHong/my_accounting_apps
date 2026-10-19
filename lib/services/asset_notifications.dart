import 'package:flutter/foundation.dart';

/// Lets pages retained in the tab view refresh after an account is saved.
final ValueNotifier<int> assetAccountsRevision = ValueNotifier<int>(0);

void notifyAssetAccountsChanged() {
  assetAccountsRevision.value++;
}
