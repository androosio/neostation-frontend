import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/widgets/collection_badge.dart';

/// The mark a game carries when it is filed in a collection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    builder: (context, _) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  testWidgets('the plate form sizes itself to the host card', (tester) async {
    await tester.pumpWidget(host(const CollectionBadge(size: 22)));
    final box = tester.widget<Container>(
      find
          .ancestor(
            of: find.byIcon(Symbols.bookmark_rounded),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((box.constraints?.maxWidth ?? 0), 22);
  });

  testWidgets('the inline form is the glyph alone, in the row colour', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const CollectionBadge.inline(color: Colors.orange)),
    );
    final icon = tester.widget<Icon>(find.byIcon(Symbols.bookmark_rounded));
    expect(icon.color, Colors.orange);
    // No plate behind it: a text row has no artwork to sit on.
    expect(find.byType(Container), findsNothing);
  });

  group('CollectionsProvider.isInAnyCollection', () {
    test('a game with no rom path is never a member', () {
      final provider = CollectionsProvider();
      expect(provider.isInAnyCollection(null), isFalse);
      expect(provider.isInAnyCollection(''), isFalse);
    });

    test('an unknown rom path is not a member before anything is loaded', () {
      final provider = CollectionsProvider();
      expect(provider.isInAnyCollection('/roms/nes/Dr. Mario.zip'), isFalse);
    });
  });
}
