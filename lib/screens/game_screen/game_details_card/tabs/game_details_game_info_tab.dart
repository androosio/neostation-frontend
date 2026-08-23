import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../providers/file_provider.dart';
import '../../../../services/screenscraper_service.dart';
import '../../../../themes/chrome_surface.dart';
import '../../../../themes/corner_radii.dart';
import '../../../../utils/game_utils.dart';
import '../widgets/header_action_button.dart';

class GameDetailsGameInfoTab extends StatefulWidget {
  final SystemModel system;
  final GameModel game;
  final FileProvider fileProvider;
  final String description;

  /// Hides the metadata pills while the card's scrape panel covers this tab.
  final bool isScrapingGame;
  final VoidCallback onScrapeGame;

  /// How far above the card's bottom edge the panel stops, in the same
  /// unscaled units as the other offsets. The card works it out from what the
  /// footer under it will draw, so the panel takes back the room a missing
  /// achievements pill leaves behind.
  final double bottomOffset;

  const GameDetailsGameInfoTab({
    super.key,
    required this.system,
    required this.game,
    required this.fileProvider,
    required this.description,
    required this.isScrapingGame,
    required this.onScrapeGame,
    this.bottomOffset = 110.0,
  });

  @override
  State<GameDetailsGameInfoTab> createState() => GameDetailsGameInfoTabState();
}

class GameDetailsGameInfoTabState extends State<GameDetailsGameInfoTab> {
  static const List<String> _languageLabels = [
    'en',
    'es',
    'fr',
    'de',
    'it',
    'pt',
    'jp',
    'ko',
    'ru',
    'zh',
    'nl',
    'sv',
    'da',
    'fi',
    'no',
    'pl',
    'hu',
    'cs',
    'ro',
  ];

  static const Map<String, String> _languageNames = {
    'en': 'English',
    'es': 'Espanol',
    'fr': 'Francais',
    'de': 'Deutsch',
    'it': 'Italiano',
    'pt': 'Portugues',
    'jp': 'Japanese',
    'ko': 'Korean',
    'zh': 'Chinese',
    'nl': 'Nederlands',
    'sv': 'Svenska',
    'da': 'Dansk',
    'fi': 'Suomi',
    'no': 'Norsk',
    'pl': 'Polski',
    'hu': 'Magyar',
    'cs': 'Cesky',
    'ro': 'Romanian',
  };

  String _selectedLanguage = 'en';

  /// Drives the description pane: the D-pad scrolls it while the panel is
  /// active, and a finger can drag it at any time.
  final ScrollController _descriptionController = ScrollController();

  /// Keeps the focused language chip inside its horizontal strip.
  final Map<int, GlobalKey> _languageKeys = {};

  /// Whether the panel owns the D-pad.
  ///
  /// Same gate as the achievements panel: arriving on this tab must not
  /// swallow the D-pad, so left/right keep walking the tabs and up/down keep
  /// moving the games list until A steps in. B steps back out.
  bool _isPanelActive = false;

  /// How far one D-pad press moves the description: about three lines, so a
  /// press is a readable step rather than a jump.
  double get _scrollStep => 56.r;

  /// Whether the panel currently owns the D-pad.
  bool get isPanelActive => _isPanelActive;

  /// Whether the description is longer than its pane.
  bool get _canScroll =>
      _descriptionController.hasClients &&
      _descriptionController.position.maxScrollExtent > 0;

  /// Hands the D-pad to the panel. Returns whether the input was consumed.
  ///
  /// Refuses when there is nothing to drive — a description that fits and a
  /// single language leave the D-pad better spent on the tabs and the list.
  bool enterPanel() {
    if (_isPanelActive) return true; // Already inside — A stays consumed.
    if (!_canScroll && _availableLanguages().length < 2) return false;

    setState(() => _isPanelActive = true);
    return true;
  }

  /// Gives the D-pad back to the details card. Returns whether it was held.
  bool exitPanel() {
    if (!_isPanelActive) return false;

    setState(() => _isPanelActive = false);
    return true;
  }

  /// Gamepad navigation delegate: scrolls the description up one step.
  void moveUp() => _scrollDescription(-_scrollStep);

  /// Gamepad navigation delegate: scrolls the description down one step.
  void moveDown() => _scrollDescription(_scrollStep);

  /// Gamepad navigation delegate: previous description language.
  void moveLeft() => _stepLanguage(-1);

  /// Gamepad navigation delegate: next description language.
  void moveRight() => _stepLanguage(1);

  void _scrollDescription(double delta) {
    if (!_isPanelActive || !_descriptionController.hasClients) return;

    final position = _descriptionController.position;
    final target = (position.pixels + delta).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.5) return;

    _descriptionController.animateTo(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  /// Walks the language strip by [delta], clamped to its ends.
  ///
  /// The chip is the selection, so a step applies the language outright rather
  /// than parking a cursor on it that A would then have to confirm.
  void _stepLanguage(int delta) {
    if (!_isPanelActive) return;

    final languages = _availableLanguages();
    if (languages.length < 2) return;

    final current = languages.indexOf(_selectedLanguage);
    final next = ((current < 0 ? 0 : current) + delta).clamp(
      0,
      languages.length - 1,
    );
    if (next == current) return;

    setState(() => _selectedLanguage = languages[next]);
    // A new language is a new text: start it from the top.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_descriptionController.hasClients) {
        _descriptionController.jumpTo(0);
      }
      final key = _languageKeys[next];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: 0.5,
        );
      }
    });
  }

  @override
  void didUpdateWidget(GameDetailsGameInfoTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    // A new game is a new panel: drop the gate and start its text from the
    // top, and fall back to English if it has nothing in the language the
    // previous game was being read in.
    if (oldWidget.game.romPath != widget.game.romPath) {
      _isPanelActive = false;
      if (!_availableLanguages().contains(_selectedLanguage)) {
        _selectedLanguage = 'en';
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _descriptionController.hasClients) {
          _descriptionController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  List<String> _availableLanguages() {
    final descriptions = widget.game.descriptions;
    if (descriptions == null || descriptions.isEmpty) return [];
    return _languageLabels
        .where(
          (lang) =>
              descriptions[lang] != null && descriptions[lang]!.isNotEmpty,
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final description = widget.description;

    final bool showScrapeView =
        description.isEmpty ||
        description == AppLocale.noDescription.getString(context) ||
        description.trim().isEmpty;

    return Positioned(
      left: 12.r,
      right: 12.r,
      top: 55.r,
      bottom: widget.bottomOffset.r,
      child: Container(
        decoration: BoxDecoration(
          color: ChromeSurface.fill(context),
          borderRadius:
              Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
              BorderRadius.circular(14.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            width: 1.r,
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: 0.25),
              blurRadius: 2.r,
              offset: Offset(2.0.r, 2.0.r),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0.r),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Symbols.description_rounded,
                        color: Theme.of(context).colorScheme.onSurface,
                        size: 13.r,
                      ),
                      SizedBox(width: 6.r),
                      Text(
                        AppLocale.gameInfo.getString(context),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 12.r,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      // The gate's affordance, as on the achievements panel:
                      // which button takes the D-pad into the description and
                      // which gives it back. Only drawn when there is
                      // something in here to drive.
                      if (!showScrapeView &&
                          (_canScroll || _availableLanguages().length > 1)) ...[
                        HeaderActionButton(
                          icon: Image.asset(
                            _isPanelActive
                                ? 'assets/images/gamepad/Xbox_B_button.png'
                                : 'assets/images/gamepad/Xbox_A_button.png',
                            width: 12.r,
                            height: 12.r,
                          ),
                          label:
                              (_isPanelActive
                                      ? AppLocale.back.getString(context)
                                      : AppLocale.navigate.getString(context))
                                  .toUpperCase(),
                          onTap: () {
                            SfxService().playNavSound();
                            if (_isPanelActive) {
                              exitPanel();
                            } else {
                              enterPanel();
                            }
                          },
                          backgroundColor: _isPanelActive
                              ? Theme.of(context).colorScheme.secondary
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                          foregroundColor: _isPanelActive
                              ? Theme.of(context).colorScheme.onSecondary
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                        SizedBox(width: 8.r),
                      ],
                      if (!showScrapeView &&
                          !widget.isScrapingGame &&
                          (widget.game.developer.isNotEmpty ||
                              widget.game.players.isNotEmpty ||
                              widget.game.year.isNotEmpty))
                        Row(
                          children: [
                            if (widget.game.developer.isNotEmpty)
                              _InfoPill(
                                icon: Symbols.business_rounded,
                                text: widget.game.developer,
                              ),
                            if (widget.game.players.isNotEmpty)
                              _InfoPill(
                                icon: Symbols.people_rounded,
                                text: widget.game.players,
                              ),
                            if (widget.game.year.isNotEmpty)
                              _InfoPill(
                                icon: Symbols.calendar_today_rounded,
                                text:
                                    RegExp(
                                      r'\d{4}',
                                    ).stringMatch(widget.game.year) ??
                                    widget.game.year,
                              ),
                          ],
                        ),
                    ],
                  ),
                  Divider(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                    height: 10.r,
                  ),
                ],
              ),
            ),

            Expanded(
              child: Padding(
                padding: EdgeInsets.all(8.r),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // While scraping, the card lays ScrapingProgressPanel over
                    // this whole region — every tab gets the same feedback, so
                    // this tab no longer draws its own copy.
                    return showScrapeView
                        ? _buildNonScrapedView()
                        : _buildScrapedView();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNonScrapedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppLocale.incompleteMetadata.getString(context),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20.r,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12.r),
          SizedBox(
            width: 300.r,
            child: Text(
              AppLocale.scrapeToDownload.getString(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
                fontSize: 12.r,
                height: 1.5,
              ),
            ),
          ),
          SizedBox(height: 32.r),
          FutureBuilder<bool>(
            future: ScreenScraperService.hasSavedCredentials(),
            builder: (context, snapshot) {
              if (widget.system.folderName == 'android-apps') {
                return Text(
                  AppLocale.scrapingUnavailableAndroid.getString(context),
                  style: TextStyle(fontSize: 10.r, color: Colors.grey),
                );
              }
              final hasCredentials = snapshot.data ?? false;
              if (!hasCredentials) {
                return Text(
                  AppLocale.loginToScrape.getString(context),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 10.r,
                    fontStyle: FontStyle.italic,
                  ),
                );
              }

              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  /// The description pane.
  ///
  /// It used to scroll itself on a timer, which meant the text was moving
  /// under the reader and there was no way to hold it still or go back a
  /// paragraph. It stays put now: a finger drags it, and the D-pad steps it
  /// once the panel has been activated.
  Widget _buildDescription(String text) {
    return SingleChildScrollView(
      controller: _descriptionController,
      physics: const BouncingScrollPhysics(),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
          fontSize: 11.r,
          height: 1.6,
        ),
      ),
    );
  }

  Widget _buildScrapedView() {
    final availableLanguages = _availableLanguages();

    if (availableLanguages.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(12.r),
        child: _buildDescription(
          GameUtils.cleanupDescription(widget.description),
        ),
      );
    }

    final activeDesc = widget.game.getDescriptionForLanguage(_selectedLanguage);

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12.r),
            child: _buildDescription(
              GameUtils.cleanupDescription(
                activeDesc.isNotEmpty ? activeDesc : widget.description,
              ),
            ),
          ),
        ),
        if (availableLanguages.length > 1)
          Container(
            height: 28.r,
            margin: EdgeInsets.only(bottom: 4.r),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: 8.r),
              itemCount: availableLanguages.length,
              separatorBuilder: (_, _) => SizedBox(width: 4.r),
              itemBuilder: (context, index) {
                final lang = availableLanguages[index];
                final isSelected = lang == _selectedLanguage;
                return Material(
                  key: _languageKeys.putIfAbsent(index, () => GlobalKey()),
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6.r),
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _selectedLanguage = lang;
                        // A tap is the touch equivalent of the A gate.
                        _isPanelActive = true;
                      });
                    },
                    borderRadius: BorderRadius.circular(6.r),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8.r,
                        vertical: 4.r,
                      ),
                      child: Text(
                        _languageNames[lang] ?? lang.toUpperCase(),
                        style: TextStyle(
                          color: isSelected
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.onSurface,
                          fontSize: 9.r,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.r),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 10.r,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          SizedBox(width: 4.r),
          Text(
            text,
            style: TextStyle(
              fontSize: 9.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
