import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../../sync/providers/neo_sync_adapter.dart';
import '../../sync/providers/romm_provider.dart';
import '../../sync/sync_manager.dart';
import '../../utils/gamepad_nav.dart';
import '../../widgets/custom_notification.dart';
import '../app_screen.dart';

/// Self-contained RomM connect / account panel for the top-level RomM tab.
///
/// When disconnected it shows the server credential form (URL / user / password
/// + connect). When connected it shows the server status plus the save-sync
/// toggle, a disconnect action, and — when [onBrowse] is provided — a shortcut
/// back to the library browser. Unlike the old settings panel this widget owns
/// its own gamepad navigation layer so it works as a standalone tab.
class RommConnectContent extends StatefulWidget {
  /// Invoked by the "back to library" action while connected. Null when the
  /// panel is shown as the disconnected landing view (nothing to go back to).
  final VoidCallback? onBrowse;

  const RommConnectContent({super.key, this.onBrowse});

  @override
  State<RommConnectContent> createState() => _RommConnectContentState();
}

class _RommConnectContentState extends State<RommConnectContent> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = List.generate(6, (_) => GlobalKey());

  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final FocusNode _userFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  late final GamepadNavigation _gamepadNav;
  int _index = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _moveUp,
      onNavigateDown: _moveDown,
      onSelectItem: _selectCurrent,
      onBack: _handleBack,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<RommProvider>();
      _urlController.text = provider.serverUrl;
      _userController.text = provider.username;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'romm_connect',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('romm_connect');
    _gamepadNav.dispose();
    _scrollController.dispose();
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // ── Gamepad navigation ──────────────────────────────────────────────────────

  int get _itemCount => context.read<RommProvider>().isConnected ? 3 : 4;

  void _moveUp() {
    final n = _itemCount;
    setState(() => _index = (_index - 1 + n) % n);
    _scrollToIndex(_index);
  }

  void _moveDown() {
    final n = _itemCount;
    setState(() => _index = (_index + 1) % n);
    _scrollToIndex(_index);
  }

  void _selectCurrent() {
    final provider = context.read<RommProvider>();
    if (provider.isConnected) {
      switch (_index) {
        case 0:
          widget.onBrowse?.call();
          break;
        case 1:
          _toggleSaveSync();
          break;
        case 2:
          _disconnect();
          break;
      }
      return;
    }
    switch (_index) {
      case 0:
        _urlFocus.requestFocus();
        break;
      case 1:
        _userFocus.requestFocus();
        break;
      case 2:
        _passwordFocus.requestFocus();
        break;
      case 3:
        _connect();
        break;
    }
  }

  void _handleBack() {
    // If a field currently holds the on-screen keyboard, the B button drops it
    // (only LB/RB/B pass through while a TextField is focused on Android).
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary.hasFocus && primary.context != null) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    // Otherwise, when connected, back returns to the library browser.
    widget.onBrowse?.call();
  }

  void _scrollToIndex(int index) {
    if (index < 0 || index >= _itemKeys.length) return;
    final ctx = _itemKeys[index].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  bool _validateInputs() {
    if (_urlController.text.trim().isEmpty ||
        _userController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.rommCredentialsRequired.getString(context),
        type: NotificationType.error,
      );
      return false;
    }
    return true;
  }

  Future<void> _connect() async {
    if (_busy || !_validateInputs()) return;
    setState(() => _busy = true);
    final provider = context.read<RommProvider>();
    final error = await provider.connect(
      serverUrl: _urlController.text.trim(),
      username: _userController.text.trim(),
      password: _passwordController.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      AppNotification.showNotification(
        context,
        error,
        type: NotificationType.error,
      );
    } else {
      _passwordController.clear();
      // Reset selection so the connected view starts on the first row.
      setState(() => _index = 0);
      AppNotification.showNotification(
        context,
        AppLocale.rommConnectionSuccess.getString(context),
        type: NotificationType.success,
      );
    }
  }

  Future<void> _disconnect() async {
    final provider = context.read<RommProvider>();
    await provider.disconnect();
    if (!mounted) return;
    _passwordController.clear();
    setState(() => _index = 0);
  }

  bool get _isSaveSyncActive =>
      SyncManager.instance.activeProviderId == RomMSyncProvider.kProviderId;

  /// Toggles whether RomM is the active save-sync provider (vs NeoSync).
  Future<void> _toggleSaveSync() async {
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    final target = _isSaveSyncActive
        ? NeoSyncAdapter.kProviderId
        : RomMSyncProvider.kProviderId;
    await SyncManager.instance.setActive(target, persist: persist);
    if (!mounted) return;
    setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<RommProvider>();

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.rommLibrary.getString(context),
            style: TextStyle(fontSize: 18.r, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 10.r),
          _buildStatusLine(theme, provider),
          SizedBox(height: 14.r),
          if (provider.isConnected)
            ..._buildConnectedRows(theme)
          else
            ..._buildCredentialRows(theme),
        ],
      ),
    );
  }

  Widget _buildStatusLine(ThemeData theme, RommProvider provider) {
    final connected = provider.isConnected;
    final String text;
    if (connected) {
      text = AppLocale.rommConnectedAs
          .getString(context)
          .replaceAll('{user}', provider.username);
    } else if (provider.status == RommConnectionStatus.connecting) {
      text = AppLocale.rommConnecting.getString(context);
    } else {
      text = AppLocale.rommStatusDisconnected.getString(context);
    }
    return Row(
      children: [
        Icon(
          connected ? Symbols.cloud_done_rounded : Symbols.cloud_off_rounded,
          size: 16.r,
          color: connected
              ? Colors.greenAccent
              : theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildCredentialRows(ThemeData theme) {
    return [
      _buildFieldRow(
        theme,
        index: 0,
        label: AppLocale.rommServerUrl.getString(context),
        hint: AppLocale.rommServerUrlHint.getString(context),
        controller: _urlController,
        focusNode: _urlFocus,
      ),
      SizedBox(height: 10.r),
      _buildFieldRow(
        theme,
        index: 1,
        label: AppLocale.username.getString(context),
        hint: AppLocale.enterUsername.getString(context),
        controller: _userController,
        focusNode: _userFocus,
      ),
      SizedBox(height: 10.r),
      _buildFieldRow(
        theme,
        index: 2,
        label: AppLocale.password.getString(context),
        hint: AppLocale.enterPassword.getString(context),
        controller: _passwordController,
        focusNode: _passwordFocus,
        obscure: true,
      ),
      SizedBox(height: 14.r),
      _buildActionRow(
        theme,
        index: 3,
        icon: Symbols.link_rounded,
        label: _busy
            ? AppLocale.rommConnecting.getString(context)
            : AppLocale.rommSaveConnect.getString(context),
        primary: true,
        onTap: _connect,
      ),
    ];
  }

  List<Widget> _buildConnectedRows(ThemeData theme) {
    return [
      _buildActionRow(
        theme,
        index: 0,
        icon: Symbols.grid_view_rounded,
        label: AppLocale.rommBrowseLibrary.getString(context),
        primary: true,
        onTap: () => widget.onBrowse?.call(),
      ),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 1,
        icon: Symbols.cloud_sync_rounded,
        label: AppLocale.rommUseForSaveSync.getString(context),
        primary: _isSaveSyncActive,
        toggleValue: _isSaveSyncActive,
        onTap: _toggleSaveSync,
      ),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 2,
        icon: Symbols.logout_rounded,
        label: AppLocale.rommDisconnect.getString(context),
        onTap: _disconnect,
      ),
    ];
  }

  Widget _buildFieldRow(
    ThemeData theme, {
    required int index,
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focusNode,
    bool obscure = false,
  }) {
    final selected = _index == index;
    return Container(
      key: _itemKeys[index],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w500,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 4.r),
          SizedBox(
            height: 34.r,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              obscureText: obscure,
              enabled: !_busy,
              style: TextStyle(fontSize: 11.r),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                hintStyle: TextStyle(
                  fontSize: 10.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
                filled: true,
                fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.r),
                  borderSide: BorderSide(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withValues(alpha: 0.1),
                    width: selected ? 2.r : 1.r,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.r),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 1.5.r,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(
    ThemeData theme, {
    required int index,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    bool? toggleValue,
  }) {
    final selected = _index == index;
    final scheme = theme.colorScheme;
    final borderColor = selected ? scheme.primary : scheme.outline;
    final bgColor = primary
        ? scheme.primary.withValues(alpha: selected ? 0.22 : 0.12)
        : scheme.onSurface.withValues(alpha: selected ? 0.10 : 0.04);
    return Container(
      key: _itemKeys[index],
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : onTap,
          borderRadius: BorderRadius.circular(8.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: borderColor,
                width: selected ? 2.r : 1.r,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18.r, color: scheme.primary),
                SizedBox(width: 10.r),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (_busy) ...[
                  SizedBox(width: 10.r),
                  SizedBox(
                    width: 12.r,
                    height: 12.r,
                    child: CircularProgressIndicator(strokeWidth: 2.r),
                  ),
                ],
                if (toggleValue != null) ...[
                  const Spacer(),
                  Switch(
                    value: toggleValue,
                    onChanged: _busy ? null : (_) => onTap(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
