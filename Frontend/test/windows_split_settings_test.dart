import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/models/settings.dart';

void main() {
  test('Windows routing settings survive serialization in both modes', () {
    for (final mode in ['blacklist', 'whitelist']) {
      final settings = Settings(
        windowsSplitEnabled: true,
        windowsSplitMode: mode,
        windowsSplitDomains: 'example.com\nпример.рф',
        windowsSplitPrograms: r'C:\Apps\browser.exe',
      );
      final restored = Settings.fromJson(settings.toJson());
      expect(restored.windowsSplitEnabled, isTrue);
      expect(restored.windowsSplitMode, mode);
      expect(restored.windowsSplitDomains, settings.windowsSplitDomains);
      expect(restored.windowsSplitPrograms, settings.windowsSplitPrograms);
    }
  });
}
