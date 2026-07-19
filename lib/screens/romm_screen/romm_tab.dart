import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/romm_provider.dart';
import 'romm_browse_screen.dart';
import 'romm_connect_content.dart';

/// Top-level RomM tab.
///
/// Hosts the whole RomM lifecycle so the library is reachable directly via
/// L1/R1 tab navigation instead of being buried inside Settings:
///  * disconnected → the connect / credentials form ([RommConnectContent]),
///    so a first-time user can connect without leaving the tab.
///  * connected → the [RommBrowseScreen] library browser. The server account
///    panel (save-sync toggle, disconnect) is reachable from the browser's
///    source menu, which flips this tab to show [RommConnectContent] again.
///
/// Each child owns its own gamepad navigation layer, so swapping between them
/// (here) pushes/pops the appropriate layer via their init/dispose lifecycle.
class RommTab extends StatefulWidget {
  const RommTab({super.key});

  @override
  State<RommTab> createState() => _RommTabState();
}

class _RommTabState extends State<RommTab> {
  bool _showAccount = false;

  @override
  Widget build(BuildContext context) {
    final connected = context.watch<RommProvider>().isConnected;

    if (!connected) {
      // Reset so re-connecting always lands back on the browser.
      _showAccount = false;
      return const RommConnectContent();
    }

    if (_showAccount) {
      return RommConnectContent(
        onBrowse: () => setState(() => _showAccount = false),
      );
    }

    return RommBrowseScreen(
      onOpenSettings: () => setState(() => _showAccount = true),
    );
  }
}
