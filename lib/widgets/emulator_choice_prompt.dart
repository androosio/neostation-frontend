import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';

import '../models/game_model.dart';
import '../models/system_model.dart';
import '../services/game/emulator_choice_gate.dart';
import 'confirm_action_dialog.dart';
import 'system_emulator_settings_dialog.dart';

/// Offers the emulator picker before a system's first launch on a RetroArch
/// core neostation cannot verify (see [EmulatorChoiceGate]).
///
/// Returns once the user has decided; the caller then launches as normal. If a
/// choice was made it is already written as the system default, so the launch
/// that follows picks it up without any extra plumbing.
class EmulatorChoicePrompt {
  EmulatorChoicePrompt._();

  static Future<void> maybeShow(
    BuildContext context,
    SystemModel system,
    GameModel game,
  ) async {
    final choice = await EmulatorChoiceGate.evaluate(system, game);
    if (choice == null || !context.mounted) return;

    // Recorded up front, not after the picker closes: whatever happens next —
    // the user picks, dismisses, or backs out — this system has had its one
    // offer, and a crash mid-picker must not re-arm it.
    await EmulatorChoiceGate.recordOffered(choice.system);
    if (!context.mounted) return;

    // replaceAll, not replaceFirst: a translation is free to name the system
    // more than once, and a stray literal "{system}" in the UI is exactly the
    // kind of thing that ships unnoticed in a locale nobody on the team reads.
    String fill(String key) => key
        .getString(context)
        .replaceAll('{core}', choice.coreName)
        .replaceAll('{system}', choice.system.realName);

    final wantsToChoose = await ConfirmActionDialog.show(
      context,
      title: fill(AppLocale.chooseEmulatorTitle),
      body: fill(AppLocale.chooseEmulatorBody),
      confirmLabel: AppLocale.chooseEmulator.getString(context),
      cancelLabel: AppLocale.launchAnyway.getString(context),
      icon: Symbols.info,
      // ConfirmActionDialog defaults its accent to the theme error colour,
      // which reads as "delete" — this dialog only tells the user something and
      // offers a choice, and nothing it does is destructive.
      accentColor: Theme.of(context).colorScheme.primary,
    );
    if (!wantsToChoose || !context.mounted) return;

    await showDialog(
      context: context,
      builder: (_) => SystemEmulatorSettingsDialog(system: choice.system),
    );
  }
}
