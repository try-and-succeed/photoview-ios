import 'package:flutter/material.dart';

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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_outlined),
            selectedIcon: Icon(Icons.photo),
            label: 'Timeline',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_album_outlined),
            selectedIcon: Icon(Icons.photo_album),
            label: 'Albums',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Places',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'People',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
