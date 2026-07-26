import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/game/emulator_choice_gate.dart';

void main() {
  group('EmulatorChoiceGate.shouldOffer', () {
    test('offers when an unverifiable core is about to be auto-selected', () {
      expect(
        EmulatorChoiceGate.shouldOffer(
          resolvedIsStandalone: false,
          alternativeCount: 3,
          alreadyOffered: false,
        ),
        isTrue,
      );
    });

    test('stays out of the way when a standalone was resolved', () {
      // A standalone is a real installed package we positively verified, so
      // there is nothing the user needs to decide.
      expect(
        EmulatorChoiceGate.shouldOffer(
          resolvedIsStandalone: true,
          alternativeCount: 3,
          alreadyOffered: false,
        ),
        isFalse,
      );
    });

    test('does not offer a choice of one', () {
      expect(
        EmulatorChoiceGate.shouldOffer(
          resolvedIsStandalone: false,
          alternativeCount: 1,
          alreadyOffered: false,
        ),
        isFalse,
      );
    });

    test('does not offer when the system has no emulators at all', () {
      expect(
        EmulatorChoiceGate.shouldOffer(
          resolvedIsStandalone: false,
          alternativeCount: 0,
          alreadyOffered: false,
        ),
        isFalse,
      );
    });

    test('asks once per system, never again', () {
      expect(
        EmulatorChoiceGate.shouldOffer(
          resolvedIsStandalone: false,
          alternativeCount: 3,
          alreadyOffered: true,
        ),
        isFalse,
      );
    });
  });
}
