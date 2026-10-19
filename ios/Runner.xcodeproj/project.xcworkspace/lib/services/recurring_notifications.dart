import 'package:flutter/foundation.dart';

/// Both the app pages and the system reminder scheduler listen to this value.
final ValueNotifier<int> recurringDataRevision = ValueNotifier<int>(0);
