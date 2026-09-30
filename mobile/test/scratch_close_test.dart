import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('close after cancel (no listener)', (tester) async {
    final c = StreamController<int>.broadcast();
    final sub = c.stream.listen((_) {});
    c.add(1);
    await tester.pump();
    await sub.cancel();
    var closed = false;
    // ignore: unawaited_futures
    c.close().then((_) => closed = true);
    await tester.pump(const Duration(seconds: 1));
    // ignore: avoid_print
    print('SCRATCH cancel-then-close: closed=$closed');
  });

  testWidgets('close with listener attached', (tester) async {
    final c = StreamController<int>.broadcast();
    final sub = c.stream.listen((_) {});
    c.add(1);
    await tester.pump();
    var closed = false;
    // ignore: unawaited_futures
    c.close().then((_) => closed = true);
    await tester.pump(const Duration(seconds: 1));
    // ignore: avoid_print
    print('SCRATCH close-with-listener: closed=$closed');
    await sub.cancel();
  });
}
