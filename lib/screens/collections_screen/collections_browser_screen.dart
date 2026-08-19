import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/services/collections/collections_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/context_menu/anchored_context_menu.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/footer_label_pill.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';

import '../../themes/corner_radii.dart';
import '../game_screen/my_games_list.dart';
import '../systems_screen/my_systems_section/grid_geometry.dart';
import '../systems_screen/my_systems_section/system_card.dart';
import 'collection_cards.dart';
import 'collection_name_dialog.dart';

/// Second level of the collections navigation: the user's collections as cards,
/// with a trailing "New collection" card.
///
/// Reached from the Collections virtual system on the systems grid/carousel.
/// Activating a collection pushes the ordinary [SystemGamesList] with a
/// synthesized `collection:<uuid>` [SystemModel] — the same trick the "All
/// Games" card uses — so no second games UI exists.
class CollectionsBrowserScreen extends StatefulWidget {
  const CollectionsBrowserScreen({super.key});

  @override
  State<CollectionsBrowserScreen> createState() =>
      _CollectionsBrowserScreenState();
}

/// Context-menu result ids. Local to this screen; the menu widget itself is
/// domain-agnostic.
const String _menuRename = 'rename';
const String _menuChangeImage = 'change_image';
const String _menuRemoveImage = 'remove_image';
const String _menuDelete = 'delete';

class _CollectionsBrowserScreenState extends State<CollectionsBrowserScreen> {
  static final _log = LoggerService.instance;

  /// Per-instance layer id. [GamepadNavigationManager.popLayer] resolves an id
  /// to the *first* matching entry, so a shared constant would let a second
  /// copy of this route unregister the first one's layer and strand its own —
  /// a dead layer that swallows input.
  static int _navLayerSeq = 0;
  late final String _navLayerId = 'collections_browser#${++_navLayerSeq}';

  late final GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();

  /// Anchor for the context menu. Attached to whichever card is selected, so
  /// only ever mounted once at a time.
  final GlobalKey _selectedCardKey = GlobalKey();

  int _selectedIndex = 0;
  bool _canPop = false;
  bool _isNavigatingBack = false;

  /// True while a dialog/picker owns the interaction, so a queued button press
  /// cannot start a second one.
  bool _isBusy = false;

  bool _isNavigatingFast = false;
  DateTime? _lastNavTime;

  /// Row pitch of the last laid-out grid, cached so scrolling the selection
  /// into view uses exactly the geometry that was painted.
  double _rowPitch = 0;
  int _cols = 1;

  @override
  void initState() {
    super.initState();

    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: _activateSelection,
      onBack: _goBack,
      onFavorite: _openContextMenu,
      // Start mirrors Y, matching the systems screen where Start opens the
      // per-card settings.
      onSettings: _openContextMenu,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();

      // Registered with the manager, not merely activated: entering a
      // collection (and, from there, launching a game) backgrounds this screen,
      // and the resume path calls GamepadNavigationManager.reactivate(), which
      // wakes the stack's *top registered* layer. Without this entry that would
      // be the systems grid still mounted underneath, and two navigators would
      // then handle the same press.
      GamepadNavigationManager.pushLayer(
        _navLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );

      final provider = context.read<CollectionsProvider>();
      if (!provider.hasLoaded) provider.load();
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_navLayerId);
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Model ──────────────────────────────────────────────────────────────────

  List<CollectionModel> get _collections =>
      context.read<CollectionsProvider>().collections;

  /// Collections plus the trailing "New collection" card.
  int get _cardCount => _collections.length + 1;

  /// Whether the cursor sits on the "New collection" card.
  bool get _onCreateCard => _selectedIndex >= _collections.length;

  /// The selected collection, or null when the create card is selected.
  CollectionModel? get _selectedCollection =>
      _onCreateCard ? null : _collections[_selectedIndex];

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _navigateUp() {
    if (_selectedIndex >= _cols) _updateSelection(_selectedIndex - _cols);
  }

  void _navigateDown() {
    final count = _cardCount;
    if (_selectedIndex + _cols < count) {
      _updateSelection(_selectedIndex + _cols);
    } else if (_selectedIndex < count - 1) {
      // Boundary: snap to the last card rather than refusing to move.
      _updateSelection(count - 1);
    }
  }

  void _navigateLeft() {
    if (_selectedIndex > 0) _updateSelection(_selectedIndex - 1);
  }

  void _navigateRight() {
    if (_selectedIndex < _cardCount - 1) _updateSelection(_selectedIndex + 1);
  }

  void _updateSelection(int newIndex) {
    if (newIndex == _selectedIndex) return;

    final now = DateTime.now();
    _isNavigatingFast =
        _lastNavTime != null &&
        now.difference(_lastNavTime!).inMilliseconds < 150;
    _lastNavTime = now;

    SfxService().playNavSound();
    setState(() => _selectedIndex = newIndex);
    _ensureSelectedItemVisible();
  }

  void _ensureSelectedItemVisible() {
    if (!_scrollController.hasClients || _rowPitch <= 0) return;

    final selectedRow = _selectedIndex ~/ _cols;
    final totalRows = (_cardCount / _cols).ceil();

    final position = _scrollController.position;
    final viewportHeight = position.viewportDimension;

    double targetOffset;
    if (selectedRow == 0) {
      targetOffset = position.minScrollExtent;
    } else if (selectedRow >= totalRows - 1) {
      targetOffset = position.maxScrollExtent;
    } else {
      final rowCentre = selectedRow * _rowPitch + (_rowPitch / 2);
      targetOffset = (rowCentre - viewportHeight / 2).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    }

    _scrollController.animateTo(
      targetOffset,
      duration: Duration(milliseconds: _isNavigatingFast ? 180 : 360),
      curve: Curves.easeOutQuart,
    );
  }

  void _goBack() {
    if (_isNavigatingBack) return;
    _isNavigatingBack = true;

    setState(() => _canPop = true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    });
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _activateSelection() async {
    if (_isBusy) return;
    final collection = _selectedCollection;
    if (collection == null) {
      await _createCollection();
      return;
    }
    await _openCollection(collection);
  }

  /// Pushes the ordinary games list for [collection].
  ///
  /// The [SystemModel] is synthesized exactly as `_createAllGamesSystem` does
  /// for "All Games": nothing about it is persisted, and
  /// `GameListService.loadGamesForSystem` recognises the `collection:<uuid>`
  /// folder name and loads the membership.
  Future<void> _openCollection(CollectionModel collection) async {
    final fileProvider = context.read<FileProvider>();
    final target = SystemGamesList(
      system: _createCollectionSystem(collection),
      fileProvider: fileProvider,
    );

    // Held for the whole push: a bounced A press would otherwise stack a second
    // copy of the games list on top of the first.
    _isBusy = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => target),
      );
    } finally {
      _isBusy = false;
    }

    if (!mounted) return;
    // Membership (and therefore the counts) can change inside the games list.
    await context.read<CollectionsProvider>().load();
  }

  SystemModel _createCollectionSystem(CollectionModel collection) {
    final folderName = '${SystemFolderNames.collectionPrefix}${collection.id}';
    return SystemModel(
      id: folderName,
      folderName: folderName,
      realName: collection.name,
      iconImage: '/images/icons/folder-bulk.png',
      color: collection.color1 ?? kCollectionFallbackColor,
      customBackgroundPath: collection.imagePath,
      hideLogo: false,
      imageVersion: context.read<CollectionsProvider>().imageVersion,
      romCount: collection.gameCount,
      detected: true,
    );
  }

  /// Opens the per-collection menu (Y / Start).
  Future<void> _openContextMenu() async {
    if (_isBusy) return;
    final collection = _selectedCollection;
    if (collection == null) return;

    SfxService().playNavSound();

    final items = <ContextMenuItem>[
      ContextMenuItem(
        id: _menuRename,
        label: AppLocale.renameCollection.getString(context),
        icon: Symbols.edit_rounded,
      ),
      ContextMenuItem(
        id: _menuChangeImage,
        label: AppLocale.changeImage.getString(context),
        icon: Symbols.image_rounded,
      ),
      if (collection.imagePath != null)
        ContextMenuItem(
          id: _menuRemoveImage,
          label: AppLocale.removeImage.getString(context),
          icon: Symbols.hide_image_rounded,
        ),
      ContextMenuItem(
        id: _menuDelete,
        label: AppLocale.deleteCollection.getString(context),
        icon: Symbols.delete_rounded,
        separatorBefore: true,
      ),
    ];

    final result = await showAnchoredContextMenu(
      context: context,
      items: items,
      anchorKey: _selectedCardKey,
      layerId: 'collection_context_menu',
      submenuLayerId: 'collection_context_submenu',
    );

    if (!mounted || result == null) return;

    switch (result) {
      case _menuRename:
        await _renameCollection(collection);
      case _menuChangeImage:
        await _changeImage(collection);
      case _menuRemoveImage:
        await _removeImage(collection);
      case _menuDelete:
        await _deleteCollection(collection);
    }
  }

  /// Creates a collection, prompting for its name with the next unused
  /// generated name pre-filled.
  Future<void> _createCollection() async {
    final provider = context.read<CollectionsProvider>();
    final template = AppLocale.newCollectionDefaultName.getString(context);
    final existing = provider.collections.map((c) => c.name).toSet();

    var index = provider.collections.length + 1;
    var suggestion = template.replaceFirst('{number}', '$index');
    while (existing.contains(suggestion)) {
      index++;
      suggestion = template.replaceFirst('{number}', '$index');
    }

    final name = await _prompt(
      title: AppLocale.createCollection.getString(context),
      initialValue: suggestion,
      confirmLabel: AppLocale.save.getString(context),
    );
    if (name == null || !mounted) return;

    try {
      final created = await provider.create(name);
      if (!mounted) return;
      // Land the cursor on what was just made.
      final position = provider.collections.indexWhere(
        (c) => c.id == created.id,
      );
      setState(() => _selectedIndex = position >= 0 ? position : 0);
      _notify(
        AppLocale.collectionCreated
            .getString(context)
            .replaceFirst('{name}', created.name),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection creation failed: $e');
      _reportSaveError();
    }
  }

  Future<void> _renameCollection(CollectionModel collection) async {
    final name = await _prompt(
      title: AppLocale.renameCollection.getString(context),
      initialValue: collection.name,
      confirmLabel: AppLocale.save.getString(context),
    );
    if (name == null || !mounted || name == collection.name) return;

    try {
      await context.read<CollectionsProvider>().rename(collection.id, name);
    } catch (e) {
      _log.e('Collection rename failed: $e');
      _reportSaveError();
    }
  }

  Future<void> _deleteCollection(CollectionModel collection) async {
    if (_isBusy) return;
    _isBusy = true;
    bool confirmed;
    try {
      confirmed = await ConfirmActionDialog.show(
        context,
        title: AppLocale.deleteCollection.getString(context),
        body: AppLocale.deleteCollectionConfirm
            .getString(context)
            .replaceFirst('{name}', collection.name),
        confirmLabel: AppLocale.delete.getString(context),
        icon: Symbols.delete_rounded,
      );
    } finally {
      _isBusy = false;
    }
    if (!confirmed || !mounted) return;

    try {
      await context.read<CollectionsProvider>().delete(collection.id);
      if (!mounted) return;
      setState(() {
        _selectedIndex = _selectedIndex.clamp(0, _cardCount - 1);
      });
      _notify(
        AppLocale.collectionDeleted
            .getString(context)
            .replaceFirst('{name}', collection.name),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection delete failed: $e');
      _reportSaveError();
    }
  }

  /// Replaces a collection's artwork.
  ///
  /// [CollectionsService.setCollectionImage] does the copy into
  /// `<userData>/media/collections/` and evicts the image caches; the provider
  /// bumps `imageVersion`, which is what actually forces the card to repaint —
  /// the file path is unchanged, so no `ValueKey` would otherwise differ.
  Future<void> _changeImage(CollectionModel collection) async {
    if (_isBusy) return;
    _isBusy = true;
    String? pickedPath;
    try {
      pickedPath = await _pickImageFile();
    } catch (e) {
      _log.e('Collection image picker failed: $e');
    } finally {
      _isBusy = false;
    }
    if (pickedPath == null || !mounted) return;

    try {
      final saved = await context.read<CollectionsProvider>().setImage(
        collection.id,
        pickedPath,
      );
      if (!mounted) return;
      if (saved == null) {
        _reportSaveError();
        return;
      }
      _notify(
        AppLocale.imageUpdatedSuccess.getString(context),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection image update failed: $e');
      _reportSaveError();
    }
  }

  Future<void> _removeImage(CollectionModel collection) async {
    try {
      await context.read<CollectionsProvider>().clearImage(collection.id);
      if (!mounted) return;
      _notify(
        AppLocale.imageResetDefault.getString(context),
        NotificationType.success,
      );
    } catch (e) {
      _log.e('Collection image removal failed: $e');
      _reportSaveError();
    }
  }

  /// Picks an image file, using the in-app browser on Android TV.
  ///
  /// The TV branch is not optional: Google TV devices have no system file
  /// picker activity for the plugin to hand off to, so `pickFiles` returns
  /// nothing there and the action would silently do nothing.
  Future<String?> _pickImageFile() async {
    final dialogTitle = AppLocale.changeImage.getString(context);

    if (Platform.isAndroid && await PermissionService.isTelevision()) {
      if (!mounted) return null;
      return TvDirectoryPicker.showFilePicker(
        context,
        extensions: CollectionsService.supportedImageExtensions,
      );
    }

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: CollectionsService.supportedImageExtensions,
      dialogTitle: dialogTitle,
      lockParentWindow: true,
    );
    return result?.files.single.path;
  }

  /// Shows the name prompt, holding the busy flag so a bounced press cannot
  /// stack two dialogs.
  Future<String?> _prompt({
    required String title,
    required String initialValue,
    required String confirmLabel,
  }) async {
    if (_isBusy) return null;
    _isBusy = true;
    try {
      return await CollectionNameDialog.show(
        context,
        title: title,
        initialValue: initialValue,
        confirmLabel: confirmLabel,
      );
    } finally {
      _isBusy = false;
    }
  }

  void _notify(String message, NotificationType type) {
    if (!mounted) return;
    AppNotification.showNotification(context, message, type: type);
  }

  void _reportSaveError() {
    _notify(
      AppLocale.errorSavingCollection.getString(context),
      NotificationType.error,
    );
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<CollectionsProvider>();
    final collections = provider.collections;

    // A delete (or a change made by the other engine) can shorten the list
    // under the cursor.
    if (_selectedIndex > collections.length) {
      _selectedIndex = collections.length;
    }

    _cols = Responsive.getSystemsCrossAxisCountFromSize(
      context.select<SqliteConfigProvider, String>(
        (p) => p.config.systemGridColumns,
      ),
    );

    final showSpinner = provider.isLoading && !provider.hasLoaded;

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Column(
          children: [
            _buildHeader(theme, collections.length),
            if (!showSpinner && collections.isEmpty) _buildEmptyHint(theme),
            Expanded(
              child: showSpinner
                  ? const Center(child: CircularProgressIndicator())
                  : _buildGrid(collections, provider.imageVersion),
            ),
            _CollectionsFooter(
              label:
                  _selectedCollection?.name ??
                  AppLocale.createCollection.getString(context),
              countText: _selectedCollection == null
                  ? null
                  : AppLocale.gamesCount
                        .getString(context)
                        .replaceFirst(
                          '{count}',
                          '${_selectedCollection!.gameCount}',
                        ),
              showOptions: _selectedCollection != null,
              onEnter: _activateSelection,
              onOptions: _openContextMenu,
              onBack: _goBack,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, int count) {
    return Container(
      padding: EdgeInsets.only(top: 12.r, left: 16.r, right: 16.r, bottom: 4.r),
      child: Row(
        children: [
          Opacity(
            opacity: 0.8,
            child: Icon(
              Symbols.bookmarks_rounded,
              size: 16.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          SizedBox(width: 8.r),
          Text(
            AppLocale.collections.getString(context).toUpperCase(),
            style: TextStyle(
              fontSize: 12.r,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.0,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const Spacer(),
          Text(
            AppLocale.collectionsCount
                .getString(context)
                .replaceFirst('{count}', '$count')
                .toUpperCase(),
            style: TextStyle(
              fontSize: 9.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  /// Shown above the grid when there is nothing but the create card, so the
  /// screen explains itself without ever hiding the one thing that is usable.
  Widget _buildEmptyHint(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.noCollections.getString(context),
            style: TextStyle(
              fontSize: 13.r,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          SizedBox(height: 2.r),
          Text(
            AppLocale.noCollectionsSubtitle.getString(context),
            style: TextStyle(
              fontSize: 11.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  /// Manual grid of uniform cards, laid out with the same geometry helper the
  /// systems grid uses so both screens keep the same card density and spacing.
  Widget _buildGrid(List<CollectionModel> collections, int imageVersion) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dims = calculateGridDimensions(
          screenWidth: constraints.maxWidth - 12.0.r,
          cols: _cols,
          childAspectRatio: _kCardAspectRatio,
        );
        final colWidth = dims['itemWidth']!;
        final spX = dims['crossAxisSpacing']!;
        final spY = dims['mainAxisSpacing']!;
        final cardHeight = colWidth / _kCardAspectRatio;

        _rowPitch = cardHeight + spY;

        final count = collections.length + 1;
        final rows = (count / _cols).ceil();
        final totalHeight = rows * cardHeight + (rows - 1) * spY;

        double leftOf(int index) => (index % _cols) * (colWidth + spX);
        double topOf(int index) => (index ~/ _cols) * _rowPitch;

        final cards = <Widget>[
          for (int i = 0; i < count; i++)
            Positioned(
              left: leftOf(i),
              top: topOf(i),
              width: colWidth,
              height: cardHeight,
              child: RepaintBoundary(
                child: KeyedSubtree(
                  key: i == _selectedIndex ? _selectedCardKey : null,
                  child: i < collections.length
                      ? SystemCard(
                          key: ValueKey('collection_card_${collections[i].id}'),
                          info: collectionToSystemInfo(
                            collections[i],
                            imageVersion: imageVersion,
                          ),
                          isSelected: i == _selectedIndex,
                          onTap: () => _handleCardTap(i),
                        )
                      : NewCollectionCard(
                          key: const ValueKey('collection_card_new'),
                          label: AppLocale.createCollection.getString(context),
                          isSelected: i == _selectedIndex,
                          onTap: () => _handleCardTap(i),
                        ),
                ),
              ),
            ),
        ];

        return SingleChildScrollView(
          controller: _scrollController,
          clipBehavior: Clip.none,
          padding: EdgeInsets.symmetric(horizontal: 6.0.r, vertical: 4.0.r),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: SizedBox(
            height: totalHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ...cards,
                _buildFocusIndicator(
                  left: leftOf(_selectedIndex),
                  top: topOf(_selectedIndex),
                  width: colWidth,
                  height: cardHeight,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Touch users have no A button: tapping the already-selected card activates
  /// it, so the footer buttons stay optional.
  void _handleCardTap(int index) {
    if (index == _selectedIndex) {
      _activateSelection();
      return;
    }
    setState(() => _selectedIndex = index);
    _ensureSelectedItemVisible();
  }

  Widget _buildFocusIndicator({
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    final theme = Theme.of(context);
    return AnimatedPositioned(
      key: const ValueKey('focus_indicator'),
      duration: const Duration(milliseconds: 256),
      curve: Curves.fastOutSlowIn,
      left: left + 1.r,
      top: top + 1.r,
      width: width - 2.r,
      height: height - 2.r,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            borderRadius:
                theme.extension<CornerRadii>()?.radiusExternal ??
                BorderRadius.circular(14.r),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.28),
                theme.colorScheme.primary.withValues(alpha: 0.08),
                Colors.transparent,
              ],
              stops: const [0.0, 0.35, 1.0],
            ),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.55),
              width: 2.r,
            ),
          ),
        ),
      ),
    );
  }
}

/// Card aspect ratio, matching the systems grid so the two look identical.
const double _kCardAspectRatio = 0.80;

/// Footer strip: the focused collection on the left, the button legend on the
/// right. Every action it offers is also on a gamepad button.
class _CollectionsFooter extends CoreFooter {
  const _CollectionsFooter({
    required this.label,
    required this.countText,
    required this.showOptions,
    required this.onEnter,
    required this.onOptions,
    required this.onBack,
  });

  final String label;
  final String? countText;
  final bool showOptions;
  final VoidCallback onEnter;
  final VoidCallback onOptions;
  final VoidCallback onBack;

  @override
  bool get centerControls => false;

  @override
  bool get showVersion => false;

  @override
  Widget? buildLeftContent(BuildContext context) =>
      FooterLabelPill(label: label, countText: countText);

  @override
  List<Widget> buildControls(BuildContext context) {
    final theme = Theme.of(context);

    return [
      GamepadControl(
        iconPath: 'assets/images/gamepad/Xbox_B_button.png',
        label: AppLocale.hintBack.getString(context),
        onTap: onBack,
        backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        textColor: theme.colorScheme.onSurface,
      ),
      SizedBox(width: 8.r),
      if (showOptions) ...[
        GamepadControl(
          iconPath: 'assets/images/gamepad/Xbox_Y_button.png',
          label: AppLocale.hintOptions.getString(context),
          onTap: onOptions,
          backgroundColor: theme.colorScheme.tertiaryFixed,
          textColor: theme.colorScheme.onTertiaryFixed,
        ),
        SizedBox(width: 8.r),
      ],
      GamepadControl(
        iconPath: 'assets/images/gamepad/Xbox_A_button.png',
        label: AppLocale.enter.getString(context),
        onTap: onEnter,
        backgroundColor: theme.colorScheme.tertiary,
        textColor: theme.colorScheme.onTertiary,
      ),
    ];
  }
}
