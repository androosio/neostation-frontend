import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/screens/search_screen/search_filter.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/secondary_achievements_controller.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/game_launch_utils.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/screens/game_screen/my_games_list.dart';
import 'package:neostation/screens/app_screen.dart';

/// Library-wide ROM search & filter overlay.
///
/// Loads every game across all systems once, then filters in-memory by name
/// plus platform / developer / genre / rating / year. The filter options are
/// faceted — each chip only offers values still present in the results the
/// other criteria produce, so a filter never leads to an empty list.
///
/// Reachable as its own top-level tab; selecting a result offers Go-to-game or
/// launching it through the standard [launchGameWithDialog] flow.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// Which band currently owns gamepad focus.
///
/// The screen stacks top-to-bottom: [search] field, then the [filters] chip
/// row, then the full-width [results] list — Up/Down step between them.
/// [filterMenu] is the value picker opened from a chip; [action] is the
/// per-result chooser overlay (Go to game / Play) shown after a result is
/// selected, so launching is always an explicit step.
enum _FocusRegion { search, filters, results, filterMenu, action }

/// Ordered choices offered when a search result is selected.
///
/// [download] only ever appears for a RomM result that isn't on this device
/// yet; once it is downloaded a remote result offers the same [goTo] / [play]
/// as a local one.
enum _ResultAction { goTo, play, download }

/// One line in the results list.
///
/// Local games, the "On RomM" divider, remote ROMs and the remote section's
/// loading / error / load-more line all share a single flat list so the
/// existing index-based gamepad navigation and fixed-extent scroll maths keep
/// working unchanged. Rows the user can't focus (the header, the spinner) are
/// simply left out of the focusable index.
sealed class _ResultRow {
  const _ResultRow();
}

class _LocalRow extends _ResultRow {
  const _LocalRow(this.game);
  final DatabaseGameModel game;
}

class _RemoteHeaderRow extends _ResultRow {
  const _RemoteHeaderRow();
}

class _RemoteRow extends _ResultRow {
  const _RemoteRow(this.rom);
  final RommRom rom;
}

/// The remote section's trailing line: a spinner, an error, or "load more".
enum _RemoteStatus { loading, error, loadMore }

class _RemoteStatusRow extends _ResultRow {
  const _RemoteStatusRow(this.status);
  final _RemoteStatus status;
}

class _SearchScreenState extends State<SearchScreen> {
  late GamepadNavigation _gamepadNav;

  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  final ScrollController _resultScroll = ScrollController();

  bool _loading = true;
  List<DatabaseGameModel> _all = [];

  // Filter options for the current selection, recomputed on every change: each
  // dimension only offers values still reachable from the live results (empty
  // sets hide their chip). See [computeFacets].
  SearchFacets _facets = SearchFacets.empty;

  // Active filter values (null == Any).
  String? _platform;
  String? _developer;
  String? _genre;
  String? _year;
  int? _rating;

  _FocusRegion _region = _FocusRegion.search;
  int _barIndex = 0;
  int _resultIndex = 0;

  // Index into [_searchItems]: the text field, the clear-query X once there is
  // a query, then the Filters toggle. Filters stay collapsed by default — most
  // users only want text search.
  int _searchIndex = 0;
  bool _filtersExpanded = false;

  // Filter value-picker state, valid while _region == filterMenu. The original
  // value is snapshotted on open so Back can cancel a live preview.
  String? _menuKey;
  String? _menuOrigValue;
  int? _menuOrigRatingValue;
  final ScrollController _menuScroll = ScrollController();

  static const double _menuExtent = 44;

  // Active result-action chooser state (valid while _region == action).
  int _actionIndex = 0;
  DatabaseGameModel? _actionTarget;

  /// The RomM ROM the open chooser belongs to, when the selected row was a
  /// remote one. Mutually exclusive with [_actionTarget] being the sole target:
  /// a downloaded remote ROM sets both, so Go-to-game / Play can act on the
  /// local copy while the title shown stays the one the user picked.
  RommRom? _actionRemoteTarget;

  /// Actions offered by the currently open chooser, in display order.
  List<_ResultAction> _actionOptions = const [];

  List<DatabaseGameModel> _results = [];

  // ── RomM section ──────────────────────────────────────────────────────────
  // Local results filter synchronously on every keystroke; RomM is a paginated
  // network call, so it runs debounced and out-of-band and lands underneath the
  // local results as its own section.

  static const int _remotePageSize = 30;
  static const Duration _remoteDebounce = Duration(milliseconds: 350);

  Timer? _remoteTimer;

  /// Incremented per issued search; a response whose sequence no longer matches
  /// is a stale in-flight request and is dropped rather than rendered.
  int _remoteSeq = 0;

  List<RommRom> _remote = [];
  bool _remoteLoading = false;
  String? _remoteError;
  bool _remoteHasMore = false;
  int _remoteOffset = 0;

  /// Whether each remote ROM is already on this device, by RomM ROM id. Absent
  /// means "not resolved yet" — the badge appears once the async check lands.
  final Map<int, bool> _remoteDownloaded = {};

  /// Rows as rendered, and the subset of their indices that can take focus.
  List<_ResultRow> _rows = const [];
  List<int> _focusable = const [];

  // Resolved box-art path per ROM (null == no art); see [_resolveBoxArt].
  final Map<String, String?> _artCache = {};

  // The chip row scrolls horizontally rather than wrapping, so the focused chip
  // has to be scrolled into view; each chip carries a key to measure against.
  final ScrollController _chipScroll = ScrollController();
  final Map<int, GlobalKey> _chipKeys = {};

  // Secondary-display "Now Playing" / in-game achievements panel for games
  // launched straight from the results list. Android-only; null elsewhere.
  SecondaryDisplayState? _secondaryDisplayState;
  final SecondaryAchievementsController _achievementsController =
      SecondaryAchievementsController();

  static const double _resultExtent = 68;

  @override
  void initState() {
    super.initState();

    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: _handleSelect,
      onBack: _handleBack,
      // Search runs as a tab and owns the input layer while it is on screen,
      // so it has to keep the bumper/tab cycling working itself.
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'search_screen',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );

      // Wait for the tab indicator animation (160ms AnimatedPositioned)
      // to finish before starting any database work.
      Future.delayed(const Duration(milliseconds: 250), _loadGames);
    });

    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState.instance;
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('search_screen');
    _remoteTimer?.cancel();
    _achievementsController.dispose();
    _gamepadNav.dispose();
    _nameController.dispose();
    _nameFocus.dispose();
    _resultScroll.dispose();
    _menuScroll.dispose();
    _chipScroll.dispose();
    super.dispose();
  }

  Future<void> _loadGames() async {
    final games = await GameRepository.getAllGames();
    if (!mounted) return;

    // Phase 1: make the data available and show the loaded UI instantly
    // without any heavy computation, so the tab transition never freezes.
    setState(() {
      _all = games;
      _loading = false;
    });

    // Phase 2: after the first loaded frame is on screen, run the expensive
    // filter / sort / facet computation off the critical path.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _recompute());
    });
  }

  /// Extracts a 4-digit year from a raw year / ISO release-date string.
  String? _yearOf(DatabaseGameModel g) => searchYearOf(g);

  /// Recomputes the results *and* the filter options they support.
  ///
  /// Options are re-derived rather than taken once from the whole library, so
  /// a chip never offers a value that would return nothing. Chips can appear
  /// and disappear as a result, so the focused chip is tracked by key across
  /// the rebuild instead of by index.
  void _recompute() {
    final criteria = SearchCriteria(
      query: _nameController.text,
      platform: _platform,
      developer: _developer,
      genre: _genre,
      year: _year,
      rating: _rating,
    );

    _results = filterAndSortGames(_all, criteria);
    _rebuildRows();

    final focusedKey = _barIndex < _barItems.length
        ? _barItems[_barIndex]
        : null;
    _facets = computeFacets(_all, criteria);
    final items = _barItems;
    final moved = focusedKey == null ? -1 : items.indexOf(focusedKey);
    _barIndex = moved >= 0 ? moved : _barIndex.clamp(0, items.length - 1);

    // Emptying the query drops the clear button out of the search band.
    _searchIndex = _searchIndex.clamp(0, _lastSearchIndex);
  }

  /// Rebuilds the flat row list from the local results plus the RomM section,
  /// keeping the focused row index in range.
  ///
  /// The chip filters deliberately do not narrow the RomM section: [RommRom]
  /// carries no developer, year or rating, so applying those criteria remotely
  /// would silently drop everything. Remote results answer the text query only,
  /// which is also all the server itself matches on.
  void _rebuildRows() {
    final rows = <_ResultRow>[..._results.map(_LocalRow.new)];

    if (_remoteSectionVisible) {
      rows.add(const _RemoteHeaderRow());
      rows.addAll(_remote.map(_RemoteRow.new));
      if (_remoteError != null) {
        rows.add(const _RemoteStatusRow(_RemoteStatus.error));
      } else if (_remoteLoading) {
        rows.add(const _RemoteStatusRow(_RemoteStatus.loading));
      } else if (_remoteHasMore) {
        rows.add(const _RemoteStatusRow(_RemoteStatus.loadMore));
      }
    }

    _rows = rows;
    _focusable = [
      for (var i = 0; i < rows.length; i++)
        if (_isFocusableRow(rows[i])) i,
    ];

    if (_resultIndex >= _focusable.length) {
      _resultIndex = _focusable.isEmpty ? 0 : _focusable.length - 1;
    }
  }

  /// Headers and the spinner are skipped by Up/Down; everything else stops.
  bool _isFocusableRow(_ResultRow row) => switch (row) {
    _LocalRow() => true,
    _RemoteRow() => true,
    _RemoteStatusRow(:final status) =>
      status == _RemoteStatus.loadMore || status == _RemoteStatus.error,
    _RemoteHeaderRow() => false,
  };

  /// Whether the RomM section should appear at all.
  ///
  /// Hidden outright when RomM isn't configured or the query is blank, so an
  /// unconfigured install sees exactly the search screen it saw before.
  bool get _remoteSectionVisible =>
      _rommConfigured &&
      _nameController.text.trim().isNotEmpty &&
      (_remote.isNotEmpty || _remoteLoading || _remoteError != null);

  bool get _rommConfigured {
    try {
      return context.read<RommProvider>().isConnected;
    } catch (_) {
      // Provider absent (tests / early frames) — treat as not configured.
      return false;
    }
  }

  /// The row currently holding focus, or null when the list is empty.
  _ResultRow? get _focusedRow =>
      _resultIndex < _focusable.length ? _rows[_focusable[_resultIndex]] : null;

  // ── RomM search ───────────────────────────────────────────────────────────

  /// Restarts the debounce window after a query change.
  ///
  /// Every keystroke lands here, so the actual request only fires once typing
  /// pauses — and any in-flight response is invalidated by the bumped sequence
  /// so a slow earlier page can never overwrite a newer one.
  void _scheduleRemoteSearch() {
    _remoteTimer?.cancel();

    if (!_rommConfigured || _nameController.text.trim().isEmpty) {
      _remoteSeq++;
      setState(() {
        _remote = [];
        _remoteLoading = false;
        _remoteError = null;
        _remoteHasMore = false;
        _remoteOffset = 0;
        _rebuildRows();
      });
      return;
    }

    _remoteTimer = Timer(_remoteDebounce, () => _runRemoteSearch(reset: true));
  }

  /// Fetches one page of RomM results for the live query.
  ///
  /// Goes through [RommProvider.service] rather than `searchLibrary` on purpose:
  /// the provider keeps a single shared ROM list that the RomM browse tab is
  /// rendering, and driving it from here would reset whatever the user was
  /// browsing over there.
  Future<void> _runRemoteSearch({required bool reset}) async {
    final term = _nameController.text.trim();
    if (term.isEmpty || !_rommConfigured) return;

    final provider = context.read<RommProvider>();
    final seq = ++_remoteSeq;

    setState(() {
      if (reset) {
        _remote = [];
        _remoteOffset = 0;
        _remoteHasMore = false;
        _remoteDownloaded.clear();
      }
      _remoteLoading = true;
      _remoteError = null;
      _rebuildRows();
    });

    try {
      final page = await provider.service.getRoms(
        search: term,
        limit: _remotePageSize,
        offset: _remoteOffset,
      );
      if (!mounted || seq != _remoteSeq) return;

      setState(() {
        _remote = [..._remote, ...page];
        _remoteOffset += page.length;
        _remoteHasMore = page.length >= _remotePageSize;
        _remoteLoading = false;
        _rebuildRows();
      });

      await _resolveDownloadedFlags(page, seq);
    } on RommException catch (e) {
      if (!mounted || seq != _remoteSeq) return;
      setState(() {
        _remoteLoading = false;
        _remoteError = e.message;
        _rebuildRows();
      });
    }
  }

  /// Fills in the "already on this device" badge for a freshly fetched page.
  ///
  /// The check is a Future per ROM (it resolves the target system and stats the
  /// disk), so it runs after the rows are already on screen and the badges fade
  /// in a frame later rather than holding the whole list back.
  Future<void> _resolveDownloadedFlags(List<RommRom> page, int seq) async {
    if (page.isEmpty) return;
    final provider = context.read<RommProvider>();
    final romFolders = context.read<SqliteConfigProvider>().config.romFolders;

    final flags = await Future.wait(
      page.map((rom) => provider.isDownloadedCached(rom, romFolders)),
    );
    if (!mounted || seq != _remoteSeq) return;

    setState(() {
      for (var i = 0; i < page.length; i++) {
        _remoteDownloaded[page[i].id] = flags[i];
      }
    });
  }

  void _loadMoreRemote() {
    if (_remoteLoading || !_remoteHasMore) return;
    _runRemoteSearch(reset: false);
  }

  // ── Band model ──────────────────────────────────────────────────────────
  // Three stacked bands: search field, the filter-chip row, then results.
  // Up/Down step between bands; within the chip row Left/Right move between
  // chips. Hidden (empty-option) filters are skipped entirely.

  /// Ordered keys of the currently visible filter chips.
  ///
  /// A chip is shown when the current results still offer a choice for it, or
  /// when it is the filter doing the narrowing — an active chip has to stay
  /// reachable so it can be cleared again.
  List<String> get _visibleFilters {
    bool shown(String key) =>
        _menuOptions(key).isNotEmpty || _isFilterActive(key);
    return [
      if (shown('platform')) 'platform',
      if (_facets.ratings.isNotEmpty || _rating != null) 'rating',
      if (shown('developer')) 'developer',
      if (shown('genre')) 'genre',
      if (shown('year')) 'year',
    ];
  }

  /// Chip-row items left-to-right: each visible filter, then Clear.
  List<String> get _barItems => [..._visibleFilters, 'clear'];

  /// Number of filters currently narrowing the results (shown on the toggle
  /// so applied filters stay visible even while the chip row is collapsed).
  int get _activeFilterCount =>
      [_platform, _developer, _genre, _year].where((v) => v != null).length +
      (_rating != null ? 1 : 0);

  /// Focusable items in the search band, left-to-right. The clear button only
  /// exists while there is a query to clear.
  List<String> get _searchItems => [
    'field',
    if (_nameController.text.isNotEmpty) 'clearQuery',
    'filters',
  ];

  int get _lastSearchIndex => _searchItems.length - 1;

  /// Key of the search-band item holding focus.
  String get _focusedSearchItem =>
      _searchItems[_searchIndex.clamp(0, _lastSearchIndex)];

  /// Whether the search band owns focus and it sits on [key].
  bool _searchFocused(String key) =>
      _region == _FocusRegion.search && _focusedSearchItem == key;

  /// Shows/hides the filter chip row, moving focus to follow.
  void _toggleFilters() {
    setState(() {
      _filtersExpanded = !_filtersExpanded;
      if (_filtersExpanded) {
        _region = _FocusRegion.filters;
        _barIndex = 0;
      } else {
        _region = _FocusRegion.search;
        _searchIndex = _searchItems.indexOf('filters');
      }
    });
    SfxService().playNavSound();
  }

  /// Empties the name query, leaving the filter chips as they are, and hands
  /// focus back to the field the user was typing in.
  void _clearQuery() {
    setState(() {
      _nameController.clear();
      _searchIndex = 0;
      _recompute();
    });
    _scheduleRemoteSearch();
    SfxService().playNavSound();
  }

  // ── Navigation handlers ───────────────────────────────────────────────────

  void _navigateLeft() {
    if (_region == _FocusRegion.search) {
      setState(
        () => _searchIndex = (_searchIndex - 1).clamp(0, _lastSearchIndex),
      );
      SfxService().playNavSound();
    } else if (_region == _FocusRegion.filters) {
      setState(
        () => _barIndex = (_barIndex - 1 + _barItems.length) % _barItems.length,
      );
      _scrollChipIntoView();
      SfxService().playNavSound();
    }
  }

  void _navigateRight() {
    if (_region == _FocusRegion.search) {
      setState(
        () => _searchIndex = (_searchIndex + 1).clamp(0, _lastSearchIndex),
      );
      SfxService().playNavSound();
    } else if (_region == _FocusRegion.filters) {
      setState(() => _barIndex = (_barIndex + 1) % _barItems.length);
      _scrollChipIntoView();
      SfxService().playNavSound();
    }
  }

  void _navigateUp() {
    switch (_region) {
      case _FocusRegion.action:
        if (_actionOptions.isEmpty) return;
        setState(
          () => _actionIndex =
              (_actionIndex - 1 + _actionOptions.length) %
              _actionOptions.length,
        );
      case _FocusRegion.filterMenu:
        _moveMenuSelection(-1);
      case _FocusRegion.results:
        if (_resultIndex == 0) {
          setState(
            () => _region = _filtersExpanded
                ? _FocusRegion.filters
                : _FocusRegion.search,
          );
        } else {
          setState(() => _resultIndex -= 1);
          _scrollResultIntoView();
        }
      case _FocusRegion.filters:
        setState(() => _region = _FocusRegion.search);
      case _FocusRegion.search:
        break; // already at the top
    }
    SfxService().playNavSound();
  }

  void _navigateDown() {
    switch (_region) {
      case _FocusRegion.action:
        if (_actionOptions.isEmpty) return;
        setState(
          () => _actionIndex = (_actionIndex + 1) % _actionOptions.length,
        );
      case _FocusRegion.filterMenu:
        _moveMenuSelection(1);
      case _FocusRegion.results:
        if (_focusable.isEmpty) return;
        setState(
          () =>
              _resultIndex = (_resultIndex + 1).clamp(0, _focusable.length - 1),
        );
        _scrollResultIntoView();
        // Reaching the tail of a page pulls the next one in, so the RomM
        // section keeps growing as the user scrolls rather than needing the
        // load-more row to be selected explicitly.
        if (_resultIndex >= _focusable.length - 2) _loadMoreRemote();
      case _FocusRegion.search:
        if (_filtersExpanded) {
          setState(() {
            _nameFocus.unfocus();
            _region = _FocusRegion.filters;
          });
        } else {
          _enterResults();
        }
      case _FocusRegion.filters:
        // Flow from the chip row straight into the live results list.
        _enterResults();
    }
    SfxService().playNavSound();
  }

  /// Moves focus into the results list if it has any entries.
  void _enterResults() {
    if (_focusable.isEmpty) return;
    setState(() {
      _nameFocus.unfocus();
      _region = _FocusRegion.results;
      _resultIndex = _resultIndex.clamp(0, _focusable.length - 1);
    });
    _scrollResultIntoView();
  }

  void _handleSelect() {
    switch (_region) {
      case _FocusRegion.action:
        if (_actionIndex < _actionOptions.length) {
          _runResultAction(_actionOptions[_actionIndex]);
        }
      case _FocusRegion.filterMenu:
        // Confirm the live-previewed value.
        setState(() {
          _menuKey = null;
          _region = _FocusRegion.filters;
        });
      case _FocusRegion.search:
        switch (_focusedSearchItem) {
          case 'clearQuery':
            _clearQuery();
          case 'filters':
            _toggleFilters();
          default:
            // Hand focus to the text field so the keyboard opens.
            _nameFocus.requestFocus();
        }
      case _FocusRegion.results:
        // Open the per-result chooser instead of launching outright, so the
        // user can reveal the game in its list rather than always playing it.
        _selectFocusedRow();
      case _FocusRegion.filters:
        final item = _barItems[_barIndex];
        if (item == 'clear') {
          _clearFilters();
        } else {
          _openFilterMenu(item);
        }
    }
  }

  /// Opens the chooser for whatever row currently holds focus.
  ///
  /// A remote ROM that is already downloaded resolves to its local copy first,
  /// so it can offer the same Go-to-game / Play as a local result; one that
  /// isn't offers Download instead.
  Future<void> _selectFocusedRow() async {
    final row = _focusedRow;
    switch (row) {
      case null:
      case _RemoteHeaderRow():
        return;

      case _LocalRow(:final game):
        setState(() {
          _actionTarget = game;
          _actionRemoteTarget = null;
          _actionOptions = const [_ResultAction.goTo, _ResultAction.play];
          _actionIndex = 0;
          _region = _FocusRegion.action;
        });
        SfxService().playNavSound();

      case _RemoteStatusRow(:final status):
        // The error row doubles as a retry button.
        if (status == _RemoteStatus.error) {
          _runRemoteSearch(reset: true);
        } else if (status == _RemoteStatus.loadMore) {
          _loadMoreRemote();
        }
        SfxService().playNavSound();

      case _RemoteRow(:final rom):
        SfxService().playNavSound();
        final local = (_remoteDownloaded[rom.id] ?? false)
            ? await _localGameForRemote(rom)
            : null;
        if (!mounted) return;
        setState(() {
          _actionTarget = local;
          _actionRemoteTarget = rom;
          // A downloaded ROM we can't map back to a local row (renamed or not
          // yet rescanned) falls back to the download action, which reports
          // "already downloaded" rather than fetching it twice.
          _actionOptions = local != null
              ? const [_ResultAction.goTo, _ResultAction.play]
              : const [_ResultAction.download];
          _actionIndex = 0;
          _region = _FocusRegion.action;
        });
    }
  }

  /// Finds the locally indexed game for a downloaded RomM ROM.
  ///
  /// The rom map records the exact on-disk name written at download time,
  /// which is the only reliable key for multi-disc games whose `.m3u` basename
  /// can't be reconstructed from the ROM's `fsName`.
  Future<DatabaseGameModel?> _localGameForRemote(RommRom rom) async {
    final provider = context.read<RommProvider>();
    final system = await provider.resolveSystem(rom);
    if (system == null || !mounted) return null;

    final folder = system.primaryFolderName;
    final indexed = await RommSaveMapRepository.getIndexedNameForRomId(
      rom.id,
      folder,
    );
    if (!mounted) return null;

    final candidates = <String>{?indexed, rom.fsName}
      ..removeWhere((n) => n.isEmpty);

    for (final g in _all) {
      if (g.systemFolderName == folder && candidates.contains(g.filename)) {
        return g;
      }
    }
    return null;
  }

  void _runResultAction(_ResultAction action) {
    final target = _actionTarget;
    final remote = _actionRemoteTarget;
    setState(() => _region = _FocusRegion.results);
    switch (action) {
      case _ResultAction.play:
        if (target != null) _launch(target);
      case _ResultAction.goTo:
        if (target != null) _goToGame(target);
      case _ResultAction.download:
        if (remote != null) _downloadRemote(remote);
    }
  }

  /// Downloads a RomM ROM straight from the results list.
  ///
  /// Indexing is not this screen's job — [RommProvider.onDownloadsSettled] is
  /// wired at startup and rescans the affected system on a debounce, so the new
  /// game turns up in the local results on its own.
  Future<void> _downloadRemote(RommRom rom) async {
    final provider = context.read<RommProvider>();
    final romFolders = context.read<SqliteConfigProvider>().config.romFolders;

    if (_remoteDownloaded[rom.id] ?? false) {
      AppNotification.showNotification(
        context,
        AppLocale.rommDownloaded.getString(context),
        type: NotificationType.info,
      );
      return;
    }

    AppNotification.showNotification(
      context,
      AppLocale.rommDownloading.getString(context),
      type: NotificationType.info,
    );

    final result = await provider.downloadRom(
      rom,
      romFolders: romFolders,
      fileProvider: context.read<FileProvider>(),
    );
    if (!mounted) return;

    final (message, type) = switch (result.status) {
      RommDownloadStatus.completed => (
        AppLocale.rommDownloadComplete.getString(context),
        NotificationType.success,
      ),
      RommDownloadStatus.cancelled => (
        AppLocale.rommDownloadCancelled.getString(context),
        NotificationType.info,
      ),
      _ => (
        switch (result.error) {
          RommDownloadError.noSystemMatch => AppLocale.rommNoSystemMatch,
          RommDownloadError.noWritableFolder => AppLocale.rommNoWritableFolder,
          _ => AppLocale.rommDownloadFailed,
        }.getString(context),
        NotificationType.error,
      ),
    };
    AppNotification.showNotification(context, message, type: type);

    if (result.status == RommDownloadStatus.completed) {
      setState(() => _remoteDownloaded[rom.id] = true);
    }
  }

  void _handleBack() {
    if (_nameFocus.hasFocus) {
      _nameFocus.unfocus();
      return;
    }
    switch (_region) {
      case _FocusRegion.action:
        setState(() => _region = _FocusRegion.results);
      case _FocusRegion.filterMenu:
        _cancelFilterMenu();
      case _FocusRegion.results:
        setState(() => _region = _FocusRegion.search);
      case _FocusRegion.filters:
        setState(() => _region = _FocusRegion.search);
      case _FocusRegion.search:
        // Top of the search tab: stay put. Like every other tab, B does not
        // leave the tab — only the bumpers/tab strip change tabs.
        break;
    }
  }

  // ── Filter value menu ──────────────────────────────────────────────────────

  void _openFilterMenu(String key) {
    setState(() {
      _menuKey = key;
      _menuOrigValue = _currentFilterValue(key);
      _menuOrigRatingValue = _rating;
      _region = _FocusRegion.filterMenu;
    });
    _scrollMenuIntoView();
    SfxService().playNavSound();
  }

  /// Back out of the menu, restoring the value as it was before opening.
  void _cancelFilterMenu() {
    final key = _menuKey;
    setState(() {
      if (key == 'rating') {
        _rating = _menuOrigRatingValue;
      } else if (key != null) {
        _setFilterValue(key, _menuOrigValue);
      }
      _recompute();
      _menuKey = null;
      _region = _FocusRegion.filters;
    });
  }

  /// Moves the menu cursor by [delta], previewing the result live.
  void _moveMenuSelection(int delta) {
    final key = _menuKey;
    if (key == null) return;
    setState(() {
      if (key == 'rating') {
        _rating = cycleFilterValue(_facets.ratings, _rating, delta);
      } else {
        _setFilterValue(
          key,
          cycleFilterValue(_menuOptions(key), _currentFilterValue(key), delta),
        );
      }
      _recompute();
    });
    _scrollMenuIntoView();
  }

  /// Commits the menu entry at [index] (mouse / tap path) and closes.
  void _applyMenuIndex(String key, int index) {
    setState(() {
      if (key == 'rating') {
        _rating = index == 0 ? null : _facets.ratings[index - 1];
      } else {
        _setFilterValue(key, index == 0 ? null : _menuOptions(key)[index - 1]);
      }
      _recompute();
      _menuKey = null;
      _region = _FocusRegion.filters;
    });
  }

  List<String> _menuOptions(String key) => _facets.optionsFor(key);

  String? _currentFilterValue(String key) => switch (key) {
    'platform' => _platform,
    'developer' => _developer,
    'genre' => _genre,
    'year' => _year,
    _ => null,
  };

  void _setFilterValue(String key, String? value) {
    switch (key) {
      case 'platform':
        _platform = value;
      case 'developer':
        _developer = value;
      case 'genre':
        _genre = value;
      case 'year':
        _year = value;
    }
  }

  /// Index of the selected entry within the open menu's option list
  /// (0 == the leading "Any" slot).
  int _menuSelectedIndex(String key) {
    if (key == 'rating') {
      final cur = _rating;
      if (cur == null) return 0;
      final i = _facets.ratings.indexOf(cur);
      return i < 0 ? 0 : i + 1;
    }
    final cur = _currentFilterValue(key);
    if (cur == null) return 0;
    final i = _menuOptions(key).indexOf(cur);
    return i < 0 ? 0 : i + 1;
  }

  /// Resets every filter chip. The name query is deliberately left alone — it
  /// is the search itself, not one of the filters this button owns.
  void _clearFilters() {
    setState(() {
      _platform = null;
      _developer = null;
      _genre = null;
      _year = null;
      _rating = null;
      _recompute();
    });
    SfxService().playNavSound();
  }

  void _scrollResultIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_resultScroll.hasClients) return;
      final pos = _resultScroll.position;
      // Scroll by the row's position in the *rendered* list, not its position
      // among focusable rows — the RomM header sits between the two and would
      // otherwise offset every remote row by one slot.
      final rowPos = _resultIndex < _focusable.length
          ? _focusable[_resultIndex]
          : 0;
      final target =
          (rowPos * _resultExtent.r) -
          (pos.viewportDimension - _resultExtent.r) / 2;
      pos.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  /// Keeps the selected menu entry visible when the option list overflows.
  void _scrollMenuIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _menuKey;
      if (key == null || !_menuScroll.hasClients) return;
      final pos = _menuScroll.position;
      final target =
          (_menuSelectedIndex(key) * _menuExtent.r) -
          (pos.viewportDimension - _menuExtent.r) / 2;
      pos.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _launch(DatabaseGameModel dbGame) async {
    final folder = dbGame.systemFolderName;
    if (folder == null || folder.isEmpty) return;

    final fileProvider = context.read<FileProvider>();
    final syncProvider = context.read<SyncManager>().active;
    if (syncProvider == null) return;

    final system = await SqliteService.getSystemByFolderName(folder);
    if (!mounted) return;

    final game = GameModel.fromDatabaseModel(dbGame);

    _gamepadNav.deactivate();

    // Drive the secondary display's "Now Playing" page (and the live RA panel)
    // for this session, exactly as the games list and the Recent Games cards do
    // — without this push the bottom screen never activates for a search-result
    // launch. Fired without awaiting so it never blocks the emulator handoff;
    // it lands during launchGameWithDialog's foreground window.
    // ignore: unawaited_futures
    _achievementsController.pushForLaunch(
      state: _secondaryDisplayState,
      provider: context.read<RetroAchievementsProvider>(),
      game: game,
      systemFolderName: system.primaryFolderName,
      boxartPath: SecondaryAchievementsController.resolveBoxart(
        game,
        system.primaryFolderName,
        fileProvider,
      ),
    );

    await launchGameWithDialog(
      context: context,
      game: game,
      system: system,
      fileProvider: fileProvider,
      syncProvider: syncProvider,
      onGameClosed: () {
        // Stop the poll and hide the panel; search pushes no display state of
        // its own, so the secondary fades back to whatever art is underneath.
        _achievementsController.stop(hidePanel: true);
        GamepadNavigationManager.reactivate();
      },
      onLaunchFailed: (ctx, result) async {
        _achievementsController.stop(hidePanel: true);
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.errorLaunchingGame
                .getString(context)
                .replaceFirst('{error}', ''),
            type: NotificationType.error,
          );
        }
        GamepadNavigationManager.reactivate();
      },
    );
  }

  /// Opens the result's system game list with that game pre-selected, so the
  /// user lands on it in the normal browsing view.
  ///
  /// Search is a tab rather than an overlay, so this pushes on top of the tab
  /// and backing out of the game list returns here with the query intact.
  Future<void> _goToGame(DatabaseGameModel dbGame) async {
    final folder = dbGame.systemFolderName;
    if (folder == null || folder.isEmpty) return;

    final fileProvider = context.read<FileProvider>();
    final system = await SqliteService.getSystemByFolderName(folder);
    if (!mounted) return;

    final game = GameModel.fromDatabaseModel(dbGame);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SystemGamesList(
          system: system,
          fileProvider: fileProvider,
          initialRomPath: game.romPath,
        ),
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Tab content sits under the global header, so it carries no Scaffold or
    // AppBar of its own — the leading SizedBox clears the header the same way
    // the other tabs do (32.r tab strip + margin).
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : Stack(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 64.r),
                    _buildSearchRow(theme),
                    if (_filtersExpanded) ...[
                      SizedBox(height: 6.r),
                      _buildFilterChips(theme),
                    ],
                    SizedBox(height: 8.r),
                    Expanded(child: _buildResults(theme)),
                  ],
                ),
              ),
              if (_region == _FocusRegion.filterMenu && _menuKey != null)
                _buildFilterMenu(theme, _menuKey!),
              if (_region == _FocusRegion.action &&
                  (_actionTarget != null || _actionRemoteTarget != null))
                _buildActionChooser(theme),
            ],
          );
  }

  /// Modal overlay offering the actions available for the selected result.
  Widget _buildActionChooser(ThemeData theme) {
    final scheme = theme.colorScheme;
    final target = _actionTarget;
    final title =
        _actionRemoteTarget?.name ?? target?.realName ?? target?.filename ?? '';
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _region = _FocusRegion.results),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.6),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 320.r,
                padding: EdgeInsets.all(16.r),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(16.r),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.4),
                    width: 1.r,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15.r,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 12.r),
                    for (var i = 0; i < _actionOptions.length; i++)
                      _buildActionOption(theme, _actionOptions[i], i),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionOption(ThemeData theme, _ResultAction action, int index) {
    final scheme = theme.colorScheme;
    final isFocused = _actionIndex == index;
    final (icon, label) = switch (action) {
      _ResultAction.goTo => (
        Symbols.my_location_rounded,
        AppLocale.searchGoToGame.getString(context),
      ),
      _ResultAction.play => (
        Symbols.play_arrow_rounded,
        AppLocale.play.getString(context),
      ),
      _ResultAction.download => (
        Symbols.cloud_download_rounded,
        AppLocale.download.getString(context),
      ),
    };
    return GestureDetector(
      onTap: () {
        setState(() => _actionIndex = index);
        _runResultAction(action);
      },
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 4.r),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
        decoration: BoxDecoration(
          color: isFocused
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isFocused ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18.r,
              color: isFocused ? scheme.primary : scheme.onSurface,
            ),
            SizedBox(width: 8.r),
            Text(
              label,
              style: TextStyle(
                fontSize: 14.r,
                fontWeight: FontWeight.w700,
                color: isFocused ? scheme.primary : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The filter-chip row beneath the search box: one chip per visible filter,
  /// then Clear.
  ///
  /// Scrolls horizontally on one line instead of wrapping — wrapping cost a
  /// second full chip row of vertical space (and the results list with it) on
  /// every handheld we target, for a row that is already Left/Right navigable.
  Widget _buildFilterChips(ThemeData theme) {
    final inFilters = _region == _FocusRegion.filters;
    final items = _barItems;
    return SingleChildScrollView(
      controller: _chipScroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            KeyedSubtree(
              key: _chipKeys.putIfAbsent(i, () => GlobalKey()),
              child: items[i] == 'clear'
                  ? _buildClearChip(theme, inFilters && _barIndex == i)
                  : _buildFilterChip(
                      theme,
                      items[i],
                      inFilters && _barIndex == i,
                    ),
            ),
        ],
      ),
    );
  }

  /// Keeps the focused filter chip visible in the horizontally scrolling row.
  void _scrollChipIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chipContext = _chipKeys[_barIndex]?.currentContext;
      if (chipContext == null) return;
      Scrollable.ensureVisible(
        chipContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  /// The top band: the search field, the result count, and the Filters
  /// (advanced) toggle.
  ///
  /// The count rides in this row rather than owning a line above the list —
  /// on a handheld that line was a whole result's worth of height.
  Widget _buildSearchRow(ThemeData theme) {
    return Row(
      children: [
        Expanded(child: _buildNameField(theme, _searchFocused('field'))),
        SizedBox(width: 10.r),
        Text(
          AppLocale.searchResultsCount
              .getString(context)
              .replaceFirst('{count}', '${_results.length}'),
          style: TextStyle(
            fontSize: 12.r,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        SizedBox(width: 10.r),
        _buildAdvancedToggle(theme, _searchFocused('filters')),
      ],
    );
  }

  /// Toggle that reveals/collapses the filter chip row. Shows a count badge so
  /// applied filters remain visible while collapsed.
  Widget _buildAdvancedToggle(ThemeData theme, bool focused) {
    final scheme = theme.colorScheme;
    final count = _activeFilterCount;
    final accent = focused || count > 0;
    return GestureDetector(
      onTap: _toggleFilters,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 9.r),
        decoration: BoxDecoration(
          color: focused
              ? scheme.primary.withValues(alpha: 0.18)
              : (count > 0
                    ? scheme.primary.withValues(alpha: 0.10)
                    : scheme.surface.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: focused
                ? scheme.primary
                : (count > 0
                      ? scheme.primary.withValues(alpha: 0.5)
                      : Colors.transparent),
            width: 2.r,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.tune_rounded,
              size: 18.r,
              color: accent ? scheme.primary : scheme.onSurface,
            ),
            SizedBox(width: 6.r),
            Text(
              AppLocale.searchFilters.getString(context),
              style: TextStyle(
                fontSize: 13.r,
                fontWeight: FontWeight.w700,
                color: accent ? scheme.primary : scheme.onSurface,
              ),
            ),
            if (count > 0) ...[
              SizedBox(width: 6.r),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 1.r),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11.r,
                    fontWeight: FontWeight.w800,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ],
            SizedBox(width: 4.r),
            Icon(
              _filtersExpanded
                  ? Symbols.expand_less_rounded
                  : Symbols.expand_more_rounded,
              size: 16.r,
              color: scheme.onSurface.withValues(alpha: focused ? 0.9 : 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNameField(ThemeData theme, bool focused) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: focused ? theme.colorScheme.primary : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: TextField(
        controller: _nameController,
        focusNode: _nameFocus,
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          setState(_recompute);
          _scheduleRemoteSearch();
        },
        onSubmitted: (_) => _nameFocus.unfocus(),
        decoration: InputDecoration(
          hintText: AppLocale.searchNameHint.getString(context),
          prefixIcon: const Icon(Symbols.search_rounded),
          suffixIcon: _nameController.text.isEmpty
              ? null
              : _buildClearQueryButton(theme, _searchFocused('clearQuery')),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 12.r,
            vertical: 10.r,
          ),
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.r),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// The X inside the search field that empties the query.
  ///
  /// It is a focus stop of its own in the search band rather than a tap-only
  /// affordance, so it is reachable with the D-pad like everything else — and
  /// it only exists while there is a query, so Left/Right skip it otherwise.
  Widget _buildClearQueryButton(ThemeData theme, bool focused) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: _clearQuery,
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 6.r, vertical: 4.r),
        padding: EdgeInsets.all(4.r),
        decoration: BoxDecoration(
          color: focused
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: focused ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Icon(
          Symbols.close_rounded,
          size: 18.r,
          color: focused
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  /// A single filter chip showing "Label: value"; tapping opens its picker.
  Widget _buildFilterChip(ThemeData theme, String key, bool isFocused) {
    final scheme = theme.colorScheme;
    final label = _filterLabel(key);
    final value = _filterValueLabel(key);
    final active = _isFilterActive(key);

    return GestureDetector(
      onTap: () {
        setState(() {
          _region = _FocusRegion.filters;
          _barIndex = _barItems.indexOf(key);
        });
        _openFilterMenu(key);
      },
      child: Container(
        margin: EdgeInsets.only(right: 8.r),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: isFocused
              ? scheme.primary.withValues(alpha: 0.18)
              : (active
                    ? scheme.primary.withValues(alpha: 0.10)
                    : scheme.surface.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isFocused
                ? scheme.primary
                : (active
                      ? scheme.primary.withValues(alpha: 0.5)
                      : Colors.transparent),
            width: 2.r,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label: ',
              style: TextStyle(
                fontSize: 13.r,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 140.r),
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.r,
                  fontWeight: FontWeight.w700,
                  color: (active || isFocused)
                      ? scheme.primary
                      : scheme.onSurface,
                ),
              ),
            ),
            SizedBox(width: 4.r),
            Icon(
              Symbols.expand_more_rounded,
              size: 16.r,
              color: scheme.onSurface.withValues(alpha: isFocused ? 0.9 : 0.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClearChip(ThemeData theme, bool isFocused) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: _clearFilters,
      child: Container(
        margin: EdgeInsets.only(right: 8.r),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: isFocused
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isFocused ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.filter_alt_off_rounded,
              size: 16.r,
              color: scheme.onSurface,
            ),
            SizedBox(width: 6.r),
            Text(
              AppLocale.searchClearFilters.getString(context),
              style: TextStyle(
                fontSize: 13.r,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The value picker overlay opened from a filter chip.
  ///
  /// Sized against the real viewport rather than a fixed `.r` height: 360.r is
  /// most of a 1080p handheld's screen, which pushed a long list (platforms,
  /// years) to full height and slid its title under the global tab strip. The
  /// overlay covers the whole tab area — which starts behind the header — so it
  /// carries the same 64.r header clearance the tab content does.
  Widget _buildFilterMenu(ThemeData theme, String key) {
    final scheme = theme.colorScheme;
    final labels = _menuLabels(key);
    final selected = _menuSelectedIndex(key);

    return Positioned.fill(
      child: GestureDetector(
        onTap: _cancelFilterMenu,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.6),
          child: LayoutBuilder(
            builder: (context, viewport) {
              final topInset = 64.r + 12.r;
              final available = viewport.maxHeight - topInset - 12.r;
              return Padding(
                padding: EdgeInsets.only(top: topInset, bottom: 12.r),
                child: Center(
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(
                      width: 320.r,
                      constraints: BoxConstraints(
                        maxHeight: math.max(
                          0,
                          math.min(available, viewport.maxHeight * 0.6),
                        ),
                      ),
                      padding: EdgeInsets.all(12.r),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(16.r),
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.4),
                          width: 1.r,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(left: 4.r, bottom: 8.r),
                            child: Text(
                              _filterLabel(key),
                              style: TextStyle(
                                fontSize: 15.r,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          Flexible(
                            child: ListView.builder(
                              controller: _menuScroll,
                              shrinkWrap: true,
                              itemExtent: _menuExtent.r,
                              itemCount: labels.length,
                              itemBuilder: (context, i) => _buildMenuOption(
                                theme,
                                key,
                                labels[i],
                                i,
                                selected,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMenuOption(
    ThemeData theme,
    String key,
    String label,
    int index,
    int selected,
  ) {
    final scheme = theme.colorScheme;
    final isSelected = index == selected;
    return GestureDetector(
      onTap: () => _applyMenuIndex(key, index),
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 2.r),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: isSelected
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: isSelected ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.r,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
            if (isSelected)
              Icon(Symbols.check_rounded, size: 16.r, color: scheme.primary),
          ],
        ),
      ),
    );
  }

  String _filterLabel(String key) => switch (key) {
    'platform' => AppLocale.filterPlatform.getString(context),
    'developer' => AppLocale.filterDeveloper.getString(context),
    'genre' => AppLocale.filterGenre.getString(context),
    'rating' => AppLocale.filterRating.getString(context),
    'year' => AppLocale.filterYear.getString(context),
    _ => key,
  };

  /// Display labels for a filter's menu, with "Any" at the head.
  List<String> _menuLabels(String key) {
    final any = AppLocale.filterAny.getString(context);
    if (key == 'rating') {
      return [any, ..._facets.ratings.map(_ratingDisplay)];
    }
    return [any, ..._menuOptions(key)];
  }

  /// A rating option: the plain 1..10 score games are filed under, not a
  /// "4+" threshold — each option matches one score, like every other filter.
  String _ratingDisplay(int score) => '★ $score';

  bool _isFilterActive(String key) => switch (key) {
    'platform' => _platform != null,
    'developer' => _developer != null,
    'genre' => _genre != null,
    'year' => _year != null,
    'rating' => _rating != null,
    _ => false,
  };

  String _filterValueLabel(String key) {
    final any = AppLocale.filterAny.getString(context);
    switch (key) {
      case 'platform':
        return _platform ?? any;
      case 'developer':
        return _developer ?? any;
      case 'genre':
        return _genre ?? any;
      case 'year':
        return _year ?? any;
      case 'rating':
        final t = _rating;
        return t == null ? any : _ratingDisplay(t);
      default:
        return any;
    }
  }

  Widget _buildResults(ThemeData theme) {
    if (_rows.isEmpty) {
      return Center(
        child: Text(
          AppLocale.searchNoResults.getString(context),
          style: TextStyle(
            fontSize: 14.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _resultScroll,
      itemExtent: _resultExtent.r,
      itemCount: _rows.length,
      itemBuilder: (context, index) => switch (_rows[index]) {
        _LocalRow(:final game) => _buildResultTile(theme, game, index),
        _RemoteHeaderRow() => _buildRemoteHeader(theme),
        _RemoteRow(:final rom) => _buildRemoteTile(theme, rom, index),
        _RemoteStatusRow(:final status) => _buildRemoteStatus(
          theme,
          status,
          index,
        ),
      },
    );
  }

  /// Whether the row rendered at [rowIndex] is the focused one.
  bool _rowFocused(int rowIndex) =>
      _region == _FocusRegion.results &&
      _resultIndex < _focusable.length &&
      _focusable[_resultIndex] == rowIndex;

  /// Divider introducing the RomM section beneath the local results.
  Widget _buildRemoteHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Text(
          AppLocale.rommLibrary.getString(context).toUpperCase(),
          style: TextStyle(
            fontSize: 10.r,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
            color: scheme.primary.withValues(alpha: 0.9),
          ),
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Divider(
            height: 1.r,
            thickness: 1.r,
            color: scheme.onSurface.withValues(alpha: 0.15),
          ),
        ),
      ],
    );
  }

  /// The RomM section's trailing line: spinner, tappable error, or load-more.
  Widget _buildRemoteStatus(ThemeData theme, _RemoteStatus status, int index) {
    final scheme = theme.colorScheme;
    final isFocused = _rowFocused(index);

    if (status == _RemoteStatus.loading) {
      return Center(
        child: SizedBox(
          width: 18.r,
          height: 18.r,
          child: CircularProgressIndicator(strokeWidth: 2.r),
        ),
      );
    }

    final isError = status == _RemoteStatus.error;
    return GestureDetector(
      onTap: () => isError ? _runRemoteSearch(reset: true) : _loadMoreRemote(),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 3.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isFocused
                ? scheme.primary.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: isFocused ? scheme.primary : Colors.transparent,
              width: 2.r,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isError
                    ? Symbols.error_rounded
                    : Symbols.keyboard_arrow_down_rounded,
                size: 16.r,
                color: isError ? scheme.error : scheme.onSurface,
              ),
              SizedBox(width: 6.r),
              Flexible(
                child: Text(
                  isError
                      ? (_remoteError ??
                            AppLocale.rommConnectionFailed.getString(context))
                      : AppLocale.rommLoadMore.getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w600,
                    color: isError
                        ? scheme.error
                        : scheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A ROM that lives on the RomM server, with a check badge when this device
  /// already has it.
  Widget _buildRemoteTile(ThemeData theme, RommRom rom, int index) {
    final scheme = theme.colorScheme;
    final isFocused = _rowFocused(index);
    final downloaded = _remoteDownloaded[rom.id] ?? false;

    final subtitleParts = <String>[
      if (rom.platformSlug.isNotEmpty) rom.platformSlug,
      if (rom.fsSizeBytes > 0) _formatSize(rom.fsSizeBytes),
      if (rom.genre != null && rom.genre!.trim().isNotEmpty) rom.genre!.trim(),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: isFocused
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isFocused ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            _buildRemoteCover(theme, rom),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rom.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.r,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subtitleParts.isNotEmpty)
                    Text(
                      subtitleParts.join('  •  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.r,
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(width: 8.r),
            Icon(
              downloaded
                  ? Symbols.check_circle_rounded
                  : Symbols.cloud_download_rounded,
              size: 16.r,
              color: downloaded
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }

  /// Cover art served by the RomM server, which needs the session's auth
  /// header — [RommService.imageHeadersFor] adds it only for URLs on the
  /// configured host.
  Widget _buildRemoteCover(ThemeData theme, RommRom rom) {
    final scheme = theme.colorScheme;
    final provider = context.read<RommProvider>();
    final url = provider.service.coverUrl(rom);

    return Container(
      width: 36.r,
      height: 46.r,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.12),
          width: 1.r,
        ),
      ),
      alignment: Alignment.center,
      child: url == null
          ? Icon(
              Symbols.cloud_rounded,
              size: 18.r,
              color: scheme.onSurface.withValues(alpha: 0.35),
            )
          : Image.network(
              url,
              key: ValueKey('romm_cover_${rom.id}'),
              headers: provider.service.imageHeadersFor(url),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => Icon(
                Symbols.cloud_rounded,
                size: 18.r,
                color: scheme.onSurface.withValues(alpha: 0.35),
              ),
            ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  Widget _buildResultTile(ThemeData theme, DatabaseGameModel g, int index) {
    final scheme = theme.colorScheme;
    final isFocused = _rowFocused(index);

    final subtitleParts = <String>[
      if ((g.systemShortName ?? g.systemRealName) != null)
        (g.systemShortName ?? g.systemRealName)!,
      if (_yearOf(g) != null) _yearOf(g)!,
      if (g.developer != null && g.developer!.trim().isNotEmpty)
        g.developer!.trim(),
    ];

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: isFocused
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isFocused ? scheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            _buildBoxArt(theme, g),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    g.realName ?? g.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.r,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subtitleParts.isNotEmpty)
                    Text(
                      subtitleParts.join('  •  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.r,
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
            if (g.rating != null && g.rating! > 0) ...[
              SizedBox(width: 8.r),
              Icon(Symbols.star_rounded, size: 14.r, color: scheme.primary),
              SizedBox(width: 2.r),
              Text(
                // Stored 0..20, shown out of 10 as everywhere else in the app.
                searchRatingScore(g.rating!).toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 12.r,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Resolves a result's box art through the same path the game list uses.
  ///
  /// [GameModel.getImagePath] is the canonical resolver: it covers NeoStation's
  /// own media folder, ROMs with complex extensions, and — critically — the
  /// read-time ES-DE `downloaded_media` fallback. A raw [FileProvider.getMediaPath]
  /// lookup sees none of those, so libraries scraped through ES-DE rendered as
  /// placeholders here while showing art everywhere else.
  ///
  /// Results are memoized per ROM: the list is virtualized over the whole
  /// library, so an unmemoized lookup re-stats several candidate paths every
  /// time a tile scrolls back into view.
  String? _resolveBoxArt(DatabaseGameModel g) {
    final folder = g.systemFolderName;
    if (folder == null || folder.isEmpty) return null;

    final key = '$folder/${g.filename}';
    if (_artCache.containsKey(key)) return _artCache[key];

    final resolved = GameModel.fromDatabaseModel(
      g,
    ).getImagePath(folder, 'box2d', context.read<FileProvider>());
    final exists = resolved.isNotEmpty && File(resolved).existsSync();
    return _artCache[key] = exists ? resolved : null;
  }

  /// Box art (box2d) thumbnail for a result, or a neutral placeholder when the
  /// game has no scraped cover.
  Widget _buildBoxArt(ThemeData theme, DatabaseGameModel g) {
    final scheme = theme.colorScheme;
    final artPath = _resolveBoxArt(g);

    return Container(
      width: 36.r,
      height: 46.r,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.12),
          width: 1.r,
        ),
      ),
      alignment: Alignment.center,
      child: artPath != null
          ? Image.file(
              File(artPath),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            )
          : Icon(
              Symbols.videogame_asset_rounded,
              size: 18.r,
              color: scheme.onSurface.withValues(alpha: 0.35),
            ),
    );
  }
}
