import 'package:flutter_test/flutter_test.dart';

import '../tool/check_whole_book_preflight.dart' as checks;

void main() {
  test(
    'whole-book planning and progress preserve recording identity',
    checks.main,
  );
}
