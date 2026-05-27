import 'dart:io';
import 'package:flutter/material.dart';
import 'package:neostation/services/logger_service.dart';
import '../services/notification_service.dart';
import '../services/neosync/auth_service.dart';
import '../sync/sync_manager.dart';
import '../sync/providers/neo_sync_adapter.dart';
import '../widgets/plan_welcome_modal.dart';
import '../widgets/plan_farewell_modal.dart';
import '../services/game_service.dart';
import '../services/music_player_service.dart';
import '../providers/sqlite_config_provider.dart';
import 'package:provider/provider.dart';

/// Widget that detects when the app returns to the foreground and reactivates the gamepad
class AppLifecycleHandler extends StatefulWidget {
  final Widget child;

  const AppLifecycleHandler({super.key, required this.child});

  @override
  State<AppLifecycleHandler> createState() => _AppLifecycleHandlerState();
}

class _AppLifecycleHandlerState extends State<AppLifecycleHandler>
    with WidgetsBindingObserver {
  String? _lastKnownPlan;

  static final _log = LoggerService.instance;

  /// Determines the level of a plan (higher number = better plan)
  int _getPlanLevel(String planName) {
    switch (planName.toLowerCase()) {
      case 'free':
        return 0;
      case 'micro':
        return 1;
      case 'mini':
        return 2;
      case 'mega':
        return 3;
      case 'ultra':
        return 4;
      default:
        return 0;
    }
  }

  /// Determines whether the plan change is an upgrade or downgrade
  bool _isUpgrade(String oldPlan, String newPlan) {
    return _getPlanLevel(newPlan) > _getPlanLevel(oldPlan);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize with current plan after a delay to ensure auth is loaded
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Wait a bit more to ensure auth service is fully loaded
      await Future.delayed(Duration(milliseconds: 500));
      if (!mounted) return;
      final authService = Provider.of<AuthService>(context, listen: false);
      if (authService.isLoggedIn) {
        _lastKnownPlan = authService.currentUser?.plan;
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      await GameService.handleAppResumed();

      if (!mounted) return;

      // Re-apply secondary display preference after display reconnection.
      if (Platform.isAndroid) {
        Provider.of<SqliteConfigProvider>(
          context,
          listen: false,
        ).reapplySecondaryDisplay();
      }

      final notificationService = Provider.of<NotificationService>(
        context,
        listen: false,
      );
      notificationService.connect().catchError((error) {
        _log.e('Failed to reconnect notifications on app resume: $error');
      });

      MusicPlayerService().appResumed();

      await _checkForDataUpdates();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!mounted) return;
      Provider.of<NotificationService>(context, listen: false).suspend();
      MusicPlayerService().appPaused();
    }
  }

  Future<void> _checkForDataUpdates() async {
    final syncManager = Provider.of<SyncManager>(context, listen: false);
    final syncProvider = syncManager.active;

    // Only check if we have an authenticated provider
    if (syncProvider == null || !syncProvider.isAuthenticated) {
      return;
    }

    // Plan tracking is NeoSync-specific; gate behind provider id.
    if (syncProvider.providerId != NeoSyncAdapter.kProviderId) {
      return;
    }

    final authService = Provider.of<AuthService>(context, listen: false);

    // Only check if the user is logged in
    if (!authService.isLoggedIn) {
      return;
    }

    try {
      // Check whether the profile changed (possible plan upgrade)
      final profileResult = await authService.getProfile();
      if (profileResult['success'] == true) {
        final currentUser = authService.currentUser;
        final currentPlan = currentUser?.plan;

        // Additional check: verify authentication by attempting a simple API call
        try {
          final quota = await syncProvider.getQuota();
          if (quota == null) {
            _log.e('NeoSync authentication failed');
          }
        } catch (e) {
          _log.e('Error refreshing sync data: $e');
          // Silently handle authentication errors to prevent unauthorized API calls
        }

        // If _lastKnownPlan is null, initialize it with the current plan
        if (_lastKnownPlan == null && currentPlan != null) {
          _lastKnownPlan = currentPlan;

          return; // Do not show modal on first initialization
        }

        // Detect plan change and show appropriate modal
        if (_lastKnownPlan != null &&
            currentPlan != null &&
            _lastKnownPlan != currentPlan) {
          final isUpgrade = _isUpgrade(_lastKnownPlan!, currentPlan);

          // Delay to ensure the UI updates first
          Future.delayed(Duration(milliseconds: 1000), () {
            if (mounted) {
              if (isUpgrade) {
                // Show welcome modal for upgrades
                PlanWelcomeModal.show(context, currentPlan);
              } else {
                // Show farewell modal for downgrades
                PlanFarewellModal.show(context, _lastKnownPlan!, currentPlan);
              }
            }
          });
        }

        // Update the known plan
        _lastKnownPlan = currentPlan;
      }
    } catch (e) {
      _log.e('Error checking for data updates: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
