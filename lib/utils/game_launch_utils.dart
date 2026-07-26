import 'package:flutter/material.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/file_provider.dart';
import '../sync/i_sync_provider.dart';
import '../services/game_service.dart';
import '../services/game_launch_manager.dart';
import '../widgets/emulator_choice_prompt.dart';
import '../widgets/game_launch_dialog.dart';

/// Standardizes the game launch workflow: Session initialization -> Progress Dialog -> Delay -> Execution -> Monitoring.
///
/// Workflow details:
/// 1. Initializes a new session via [GameLaunchManager].
/// 2. Displays the [GameLaunchDialog] to show loading progress and metadata.
/// 3. Introduces a brief delay (2s) to ensure the UI has settled and provide feedback.
/// 4. Executes the emulator/game via [GameService.launchGame].
///
/// Responsibility requirements for the caller:
/// - Deactivate gamepad/keyboard navigation BEFORE calling this function.
/// - Implement [onGameClosed] to reactive navigation and refresh application state (DB, sync status, etc.).
/// - Handle [onLaunchFailed] to display error messages and perform state cleanup.
///
/// Throws:
/// - Exceptions from [GameService.launchGame] are propagated to the caller.
Future<void> launchGameWithDialog({
  required BuildContext context,
  required GameModel game,
  required SystemModel system,
  required FileProvider fileProvider,
  required ISyncProvider syncProvider,
  required VoidCallback onGameClosed,
  Future<void> Function(BuildContext context, GameLaunchResult result)?
  onLaunchFailed,
}) async {
  // Open the launch-pending window immediately so a transient app resume during
  // the dialog/handoff can't clear the Now Playing state (see
  // GameService.isGameLaunchInProgress). Closed by _registerGameLaunch on
  // success, or below on failure.
  // Before anything else: on Android, a system whose only default is a
  // RetroArch core we cannot verify gets one chance to pick an emulator. Runs
  // ahead of the pending window and the overlay so the picker owns the screen
  // on its own, and so a choice made here is already the system default by the
  // time the launch resolves one. A no-op on every launch but the first per
  // system, and on every non-core route.
  await EmulatorChoicePrompt.maybeShow(context, system, game);
  if (!context.mounted) return;

  GameService.beginLaunchPending();
  await GameLaunchManager().beginSession();
  if (!context.mounted) {
    GameService.clearLaunchPending();
    return;
  }

  // Display the launch overlay.
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => GameLaunchDialog(
      game: game,
      system: system,
      fileProvider: fileProvider,
      syncProvider: syncProvider,
      onGameClosed: onGameClosed,
    ),
  );

  // Artificial delay for UX consistency and asset loading.
  await Future.delayed(const Duration(seconds: 2));
  if (!context.mounted) {
    GameService.clearLaunchPending();
    return;
  }

  final result = await GameService.launchGame(context, system, game);

  if (result.success) {
    // Notify manager to begin background process monitoring. On success
    // _registerGameLaunch has already closed the launch-pending window
    // (isGameLaunched now covers it).
    GameLaunchManager().onGameStarted(
      emulatorExe: GameService.launchedEmulatorExe,
    );
  } else {
    // Clean up session and close dialog on failure.
    GameService.clearLaunchPending();
    GameLaunchManager().onDialogDisposed();
    if (context.mounted) Navigator.of(context).pop();
    if (onLaunchFailed != null && context.mounted) {
      await onLaunchFailed(context, result);
    }
  }
}
