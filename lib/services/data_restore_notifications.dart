import 'package:flutter/foundation.dart';

// A full restore changes every entity and cached page, including local users.
final backupDataRevision = ValueNotifier<int>(0);
void notifyDataRestored() => backupDataRevision.value++;
