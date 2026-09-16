import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'albums_screen.dart';
import 'people_screen.dart';
import 'places_screen.dart';
import 'settings_screen.dart';
import 'timeline_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = [
      l10n.navTimeline,
      l10n.navAlbums,
      l10n.navPlaces,
      l10n.navPeople,
      l10n.navSettings,
    ];

    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final labelStyle = fittingLabelStyle(
      theme.textTheme.labelMedium ?? const TextStyle(fontSize: 12),
      labels,
      tabWidth: media.size.width / labels.length,
      textScaler: media.textScaler,
    );

    return Scaffold(
      // IndexedStack keeps each tab's scroll position and loaded pages alive.
      body: IndexedStack(
        index: _index,
        children: const [
          TimelineScreen(),
          AlbumsScreen(),
          PlacesScreen(),
          PeopleScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarTheme.of(context)
            .copyWith(labelTextStyle: WidgetStatePropertyAll(labelStyle)),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (index) => setState(() => _index = index),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.photo_outlined),
              selectedIcon: const Icon(Icons.photo),
              label: labels[0],
            ),
            NavigationDestination(
              icon: const Icon(Icons.photo_album_outlined),
              selectedIcon: const Icon(Icons.photo_album),
              label: labels[1],
            ),
            NavigationDestination(
              icon: const Icon(Icons.map_outlined),
              selectedIcon: const Icon(Icons.map),
              label: labels[2],
            ),
            NavigationDestination(
              icon: const Icon(Icons.people_outline),
              selectedIcon: const Icon(Icons.people),
              label: labels[3],
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: labels[4],
            ),
          ],
        ),
      ),
    );
  }
}

/// Space a tab keeps free beside its label.
const _labelInset = 8.0;

/// The smallest share of the normal size a label is shrunk to. Past that it
/// would be hard to read, and wrapping is the lesser evil.
const minimumLabelScale = 0.75;

/// [style], made small enough that each of [labels] fits on one line.
///
/// Five tabs leave little room, and several languages name a tab with one
/// long word ("Einstellungen", "Налаштування") that would otherwise break in
/// the middle. Measured with the user's text scale, so a larger system font
/// is taken into account rather than overflowing.
@visibleForTesting
TextStyle fittingLabelStyle(
  TextStyle style,
  List<String> labels, {
  required double tabWidth,
  required TextScaler textScaler,
}) {
  // Letter spacing is dropped first: it costs width in every language and
  // adds nothing to a label this short.
  final tight = style.copyWith(letterSpacing: 0);
  final available = tabWidth - _labelInset;

  var widest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: tight),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }

  if (widest <= available || available <= 0) return tight;

  final fontSize = tight.fontSize ?? 12;
  final scale = (available / widest).clamp(minimumLabelScale, 1.0);
  return tight.copyWith(fontSize: fontSize * scale);
}
