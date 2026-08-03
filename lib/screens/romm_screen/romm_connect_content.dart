import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_locale.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../../sync/providers/neo_sync_adapter.dart';
import '../../sync/providers/romm_provider.dart';
import '../../sync/sync_manager.dart';
import '../../utils/gamepad_nav.dart';
import '../../utils/login_form_selection.dart';
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

class _RommConnectContentState extends State<RommConnectContent>
    with LoginFormSelection<RommConnectContent> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = List.generate(4, (_) => GlobalKey());

  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final FocusNode _userFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  late final GamepadNavigation _gamepadNav;
  bool _busy = false;

  /// The slots the D-pad walks, which change with the connection state:
  /// disconnected the panel is three credential fields plus connect, connected
  /// it is three action rows and no field at all. Read live, so the cursor is
  /// clamped into range the moment a connection is made or dropped — including
  /// by something other than this panel's own buttons.
  @override
  List<FocusNode?> get selectionSlots =>
      context.read<RommProvider>().isConnected
      ? const [null, null, null]
      : [_urlFocus, _userFocus, _passwordFocus, null];

  /// Every node the panel owns, not just the ones the current state shows, so
  /// focus tracking survives the switch to the connected view.
  @override
  List<FocusNode> get ownedFocusNodes => [
    _urlFocus,
    _userFocus,
    _passwordFocus,
  ];

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onSelectItem: _selectCurrent,
      onBack: _handleBack,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
      allowRepeat: false,
      isTextFieldFocused: isAnyFieldFocused,
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
    detachFocusSelectionListeners();
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

  /// Returns whether the cursor actually moved, so the gamepad handler can
  /// suppress the nav sound when the move was refused.
  bool _navigateUp() => _moveAndScroll(-1);

  bool _navigateDown() => _moveAndScroll(1);

  bool _moveAndScroll(int delta) {
    if (!moveSelection(delta)) return false;
    _scrollToIndex(selectedSlot);
    return true;
  }

  void _selectCurrent() {
    if (context.read<RommProvider>().isConnected) {
      if (isSelected(0)) {
        widget.onBrowse?.call();
      } else if (isSelected(1)) {
        _toggleSaveSync();
      } else if (isSelected(2)) {
        _disconnect();
      }
      return;
    }
    if (focusSelectedField()) return;
    _connect();
  }

  /// B leaves a focused field first — that is what it does everywhere else in
  /// the app — and only steps back to the library once nothing is focused.
  void _handleBack() {
    if (isAnyFieldFocused()) {
      exitTextEntry();
      return;
    }
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
      resetSelection();
      AppNotification.showNotification(
        context,
        AppLocale.rommConnectionSuccess.getString(context),
        type: NotificationType.success,
      );
    }
  }

  Future<void> _disconnect() async {
    final provider = context.read<RommProvider>();
    // Capture before the await: the context can't be read across the gap.
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    await provider.disconnect();
    // If RomM was the active save-sync provider, hand save sync back to
    // NeoSync. Leaving "romm" active against a server we just forgot would
    // silently stop ALL save sync — RomM errors out, NeoSync sits idle —
    // until the user thought to re-toggle it.
    if (SyncManager.instance.activeProviderId == RomMSyncProvider.kProviderId) {
      await SyncManager.instance.setActive(
        NeoSyncAdapter.kProviderId,
        persist: persist,
      );
    }
    if (!mounted) return;
    _passwordController.clear();
    resetSelection();
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

    // Match the ScreenScraper / RetroAchievements login layout: a top-anchored,
    // horizontally-scrollable row with the credential card on the left and an
    // explanatory info box on the right (info box shown only when disconnected).
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 64.r), // Space for the top navigation dock.
          Center(
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.r),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      constraints: BoxConstraints(maxWidth: 260.r),
                      child: _buildFormCard(theme, provider),
                    ),
                    if (!provider.isConnected) ...[
                      SizedBox(width: 16.r),
                      SizedBox(width: 300.r, child: _buildInfoBox(theme)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard(ThemeData theme, RommProvider provider) {
    final connected = provider.isConnected;
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (connected ? AppLocale.rommLibrary : AppLocale.rommLogin)
                      .getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ],
          ),
          // The status line is redundant on the login form (you are visibly
          // disconnected); show it only once connected, mirroring the peers.
          if (connected) ...[
            SizedBox(height: 8.r),
            _buildStatusLine(theme, provider),
          ],
          SizedBox(height: 12.r),
          if (connected)
            ..._buildConnectedRows(theme)
          else
            ..._buildCredentialRows(theme),
        ],
      ),
    );
  }

  Widget _buildInfoBox(ThemeData theme) {
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SvgPicture.asset(
                'assets/images/icons/romm-light.svg',
                width: 24.r,
                height: 24.r,
                colorFilter: ColorFilter.mode(
                  theme.colorScheme.primary,
                  BlendMode.srcIn,
                ),
                fit: BoxFit.contain,
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Text(
                  AppLocale.rommWhatIs.getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 6.r),
          Text(
            AppLocale.rommDescription.getString(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 8.r,
            ),
            softWrap: true,
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            theme,
            Symbols.grid_view_rounded,
            AppLocale.rommInfoBrowse.getString(context),
          ),
          _buildInfoItem(
            theme,
            Symbols.cloud_sync_rounded,
            AppLocale.rommInfoSaveSync.getString(context),
          ),
          _buildInfoItem(
            theme,
            Symbols.dns_rounded,
            AppLocale.rommInfoSelfHosted.getString(context),
          ),
          SizedBox(height: 6.r),
          RichText(
            softWrap: true,
            text: TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 8.r,
              ),
              children: [
                TextSpan(text: AppLocale.rommLearnMoreAt.getString(context)),
                TextSpan(
                  text: 'romm.app',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () async {
                      final url = Uri.parse('https://romm.app');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(
                          url,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(ThemeData theme, IconData icon, String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r),
      child: Row(
        children: [
          Icon(
            icon,
            size: 12.r,
            color: theme.colorScheme.primary.withValues(alpha: 0.7),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 8.r,
              ),
              softWrap: true,
            ),
          ),
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
      SizedBox(height: 8.r),
      _buildFieldRow(
        theme,
        index: 2,
        label: AppLocale.password.getString(context),
        hint: AppLocale.enterPassword.getString(context),
        controller: _passwordController,
        focusNode: _passwordFocus,
        obscure: true,
      ),
      SizedBox(height: 12.r),
      _buildConnectButton(theme),
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
    final selected = isSelected(index);
    // Mirror the ScreenScraper / RetroAchievements field: a filled input with
    // the label floating inside it, constrained to 220.r, plus a soft primary
    // glow when the gamepad cursor is on this row.
    return Container(
      key: _itemKeys[index],
      constraints: BoxConstraints(maxWidth: 220.r),
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  blurRadius: 6.r,
                  spreadRadius: 1.r,
                ),
              ],
            )
          : null,
      child: SizedBox(
        height: 32.r,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscure,
          enabled: !_busy,
          style: TextStyle(fontSize: 11.r),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 10.r,
            ),
            floatingLabelStyle: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 10.r,
              fontWeight: FontWeight.bold,
            ),
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 10.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            filled: true,
            fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide.none,
            ),
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
                width: 1.r,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Primary "Save & Connect" button, matching the RetroAchievements connect
  /// button (full-width elevated button with a gamepad-selection glow).
  Widget _buildConnectButton(ThemeData theme) {
    const index = 3;
    final selected = isSelected(index);
    return Container(
      key: _itemKeys[index],
      constraints: BoxConstraints(maxWidth: 320.r),
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  blurRadius: 8.r,
                  spreadRadius: 2.r,
                ),
              ],
            )
          : null,
      child: SizedBox(
        width: double.infinity,
        height: 32.r,
        child: ElevatedButton(
          onPressed: _busy ? null : _connect,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
            elevation: 0,
            padding: EdgeInsets.zero,
          ),
          child: _busy
              ? SizedBox(
                  width: 16.r,
                  height: 16.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.onPrimary,
                    ),
                  ),
                )
              : Text(
                  AppLocale.rommSaveConnect.getString(context),
                  style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
                ),
        ),
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
    final selected = isSelected(index);
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
