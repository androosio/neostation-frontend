import 'dart:io';

import 'package:neostation/services/logger_service.dart';

import '../../models/game_model.dart';
import '../../models/system_model.dart';
import '../../repositories/emulator_repository.dart';
import '../../utils/emulator_loader.dart';
import 'game_launch_service.dart';

/// Decides whether a launch should stop and let the user pick their emulator
/// first.
///
/// On Android neostation cannot tell whether a libretro core is installed. The
/// `.so` sits mode `0600` inside RetroArch's `0700` private data dir, so
/// `File.exists()` returns false whether the core is absent or merely
/// unreadable — which is why `MainActivity.isCoreInstalled` is tri-state and
/// fails OPEN. Nor does the failure surface afterwards: the intent is delivered
/// successfully, RetroArch shows a black screen for a moment, and the user is
/// dropped back with no error to report. There is no signal, before or after,
/// short of root.
///
/// So this does not try to detect anything. When a system is about to launch on
/// a core we picked for the user — never one they chose — it offers the
/// emulator picker once, at the only moment the choice is actionable, and
/// records the offer so it is never repeated.
class EmulatorChoiceGate {
  EmulatorChoiceGate._();

  static final _log = LoggerService.instance;

  /// Whether the launch of [game] on [system] should offer the picker first.
  ///
  /// Every condition is a reason the prompt would be noise rather than help;
  /// see [shouldOffer] for what each one means.
  static Future<EmulatorChoice?> evaluate(
    SystemModel system,
    GameModel game,
  ) async {
    final systemId = system.id;
    if (!Platform.isAndroid || systemId == null) return null;
    if (game.emulatorName != null) return null;

    try {
      final userDefault =
          await EmulatorRepository.getUserDefaultEmulatorForSystem(systemId);
      if (userDefault != null) return null;

      // The very emulator the launch is about to use. Resolved through the same
      // call GameLaunchService makes, so the gate can never disagree with what
      // actually launches.
      final resolved = await GameLaunchService.resolveDefaultInstalledEmulator(
        system,
      );
      if (resolved == null) return null;

      final available = await loadEmulatorsForSystem(system);

      if (!shouldOffer(
        resolvedIsStandalone: resolved.isStandalone,
        alternativeCount: available.length,
        alreadyOffered: await EmulatorRepository.hasOfferedEmulatorChoice(
          systemId,
        ),
      )) {
        return null;
      }

      _log.i(
        '[EmuSel] Offering emulator choice for ${system.folderName}: '
        'about to auto-launch core "${resolved.coreFilename ?? resolved.uniqueId}" '
        'with ${available.length} option(s) available',
      );
      return EmulatorChoice(
        system: system,
        coreName: resolved.coreFilename ?? resolved.uniqueId,
      );
    } catch (e) {
      // A gate that throws must never block a launch.
      _log.e('[EmuSel] Emulator choice gate failed: $e');
      return null;
    }
  }

  /// The gate's decision, split out from its I/O so it can be reasoned about
  /// and tested directly.
  ///
  /// - [resolvedIsStandalone]: a standalone emulator is a real installed
  ///   package we positively verified, so there is nothing to warn about. Only
  ///   the unverifiable core route qualifies.
  /// - [alternativeCount]: with a single emulator for the system there is no
  ///   choice to offer — the picker would show one row and change nothing.
  /// - [alreadyOffered]: asked once, never again, whatever the user decided.
  static bool shouldOffer({
    required bool resolvedIsStandalone,
    required int alternativeCount,
    required bool alreadyOffered,
  }) {
    if (resolvedIsStandalone) return false;
    if (alternativeCount < 2) return false;
    if (alreadyOffered) return false;
    return true;
  }

  /// Records that the offer was made, so it is not repeated on the next launch.
  /// Called whether the user picked an emulator or dismissed the prompt.
  static Future<void> recordOffered(SystemModel system) async {
    final systemId = system.id;
    if (systemId == null) return;
    try {
      await EmulatorRepository.markEmulatorChoiceOffered(systemId);
    } catch (e) {
      _log.e('[EmuSel] Could not record emulator choice offer: $e');
    }
  }
}

/// A pending offer to choose an emulator before launching.
class EmulatorChoice {
  const EmulatorChoice({required this.system, required this.coreName});

  final SystemModel system;

  /// The core the launch would otherwise use, named in the prompt so the user
  /// can recognise it in RetroArch's Online Updater.
  final String coreName;
}
