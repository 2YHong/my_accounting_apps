/// Remote ciphertext can be received while an editor is open, but applying
/// it must wait so saving the form preserves its original version ancestry.
class SyncEditGuard {
  static int _readers = 0;
  static bool get active => _readers > 0;
  static void Function() acquire() {
    _readers++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _readers--;
    };
  }
}
