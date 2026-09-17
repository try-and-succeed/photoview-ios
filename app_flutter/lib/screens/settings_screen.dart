import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../api/capabilities.dart';
import '../api/trusted_cas.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../l10n/languages.dart';
import '../state/app_language.dart';
import '../state/auth.dart';
import '../state/capabilities.dart';
import '../state/people_order.dart';
import '../state/slideshow.dart';
import 'scanner_screen.dart';
import '../util/image_cache.dart';
import '../widgets/insecure_notice.dart';
import '../widgets/search_limit_field.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          if (session != null)
            ListTile(
              leading: const Icon(Icons.dns),
              title: Text(l10n.settingsConnectedInstance),
              subtitle: Text(
                session.username.isEmpty
                    ? session.instanceUrl.toString()
                    : '${session.instanceUrl} · ${session.username}',
              ),
            ),
          if (InsecureConnectionNotice.riskOf(session?.endpoint) !=
              InsecureConnectionRisk.none)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: InsecureConnectionNotice(host: session!.endpoint.host),
            ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text(l10n.settingsSwitchServer),
            subtitle: Text(l10n.settingsSwitchServerSubtitle),
            onTap: () => ref.read(authProvider.notifier).switchServer(),
          ),
          if (session != null &&
              ref.watch(hasCapabilityProvider(Capability.scanner))) ...[
            const Divider(),
            _SectionHeader(l10n.settingsSectionLibrary),
            ListTile(
              leading: const Icon(Icons.radar),
              title: Text(l10n.scannerTitle),
              subtitle: Text(l10n.settingsScannerSubtitle),
              onTap: () => showScanner(Navigator.of(context)),
            ),
          ],
          if (session != null) ...[
            const Divider(),
            _SectionHeader(l10n.settingsSectionSearch),
            const SearchLimitField(),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(l10n.settingsRecheckFeatures),
              subtitle: Text(l10n.settingsRecheckFeaturesSubtitle),
              onTap: () async {
                await ref.read(recheckCapabilitiesProvider)();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.settingsRecheckStarted)),
                );
              },
            ),
          ],
          const Divider(),
          const _LanguageTile(),
          const _SlideshowTile(),
          const _PeopleOrderTile(),
          const Divider(),
          _SectionHeader(l10n.settingsSectionSecurity),
          const _CertificateAuthorities(),
          const _PinnedCertificates(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: Text(l10n.settingsClearImageCache),
            onTap: () async {
              await clearImageCache();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.settingsImageCacheCleared)),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.logout,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              l10n.settingsLogOut,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: Text(l10n.settingsLogOutSubtitle),
            onTap: () => ref.read(authProvider.notifier).logOut(),
          ),
        ],
      ),
    );
  }
}

/// In what order the people who have a name are shown.
class _PeopleOrderTile extends ConsumerWidget {
  const _PeopleOrderTile();

  static String _label(AppLocalizations l10n, PeopleOrder order) =>
      switch (order) {
        PeopleOrder.alphabetical => l10n.settingsPeopleOrderAlphabetical,
        PeopleOrder.byCount => l10n.settingsPeopleOrderByCount,
      };

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(peopleOrderProvider).valueOrNull;

    final picked = await showDialog<PeopleOrder>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.settingsPeopleOrder),
        children: [
          for (final order in PeopleOrder.values)
            _ChoiceOption(
              label: _label(l10n, order),
              selected: order == current,
              onTap: () => Navigator.of(context).pop(order),
            ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 16, top: 8),
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.actionCancel),
              ),
            ),
          ),
        ],
      ),
    );

    if (picked == null) return;
    try {
      await ref.read(peopleOrderProvider.notifier).choose(picked);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.settingsPeopleOrderNotSaved(describeError(error, l10n)),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final order =
        ref.watch(peopleOrderProvider).valueOrNull ?? PeopleOrder.alphabetical;

    return ListTile(
      leading: const Icon(Icons.sort_by_alpha),
      title: Text(l10n.settingsPeopleOrder),
      subtitle: Text(_label(l10n, order)),
      onTap: () => _choose(context, ref),
    );
  }
}

/// How long a slideshow rests on each picture.
///
/// Next to the language because it is the same kind of setting: about this
/// device and this person, with nowhere on the server to put it.
class _SlideshowTile extends ConsumerWidget {
  const _SlideshowTile();

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(slideshowSecondsProvider).valueOrNull;

    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.settingsSlideshowSeconds),
        children: [
          for (final seconds in slideshowSecondsChoices)
            _ChoiceOption(
              label: NumberFormat.decimalPattern().format(seconds),
              selected: seconds == current,
              onTap: () => Navigator.of(context).pop(seconds),
            ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 16, top: 8),
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.actionCancel),
              ),
            ),
          ),
        ],
      ),
    );

    if (picked == null) return;
    try {
      await ref.read(slideshowSecondsProvider.notifier).choose(picked);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.settingsSlideshowNotSaved(describeError(error, l10n)),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final seconds =
        ref.watch(slideshowSecondsProvider).valueOrNull ??
        defaultSlideshowSeconds;

    return ListTile(
      leading: const Icon(Icons.slideshow_outlined),
      title: Text(l10n.settingsSlideshowSeconds),
      subtitle: Text(NumberFormat.decimalPattern().format(seconds)),
      onTap: () => _choose(context, ref),
    );
  }
}

/// The app language: the device's, or one the user picks.
class _LanguageTile extends ConsumerWidget {
  const _LanguageTile();

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(appLanguageProvider).valueOrNull;

    // A record rather than the language itself, so "follow the device" (null)
    // can be told apart from dismissing the dialog.
    final picked = await showDialog<({AppLanguage? language})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.settingsLanguage),
        children: [
          _ChoiceOption(
            label: l10n.settingsLanguageSystemDefault,
            selected: current == null,
            onTap: () => Navigator.of(context).pop((language: null)),
          ),
          for (final language in appLanguages)
            _ChoiceOption(
              label: language.nativeName,
              selected: current?.code == language.code,
              onTap: () => Navigator.of(context).pop((language: language)),
            ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 16, top: 8),
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.actionCancel),
              ),
            ),
          ),
        ],
      ),
    );

    if (picked == null) return;
    try {
      await ref.read(appLanguageProvider.notifier).choose(picked.language);
    } catch (error) {
      // Worded in the language just chosen, which is in use once the frame
      // that switches to it has been built.
      await WidgetsBinding.instance.endOfFrame;
      if (!context.mounted) return;
      final chosen = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            chosen.settingsLanguageNotSaved(describeError(error, chosen)),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final chosen = ref.watch(appLanguageProvider).valueOrNull;

    return ListTile(
      leading: const Icon(Icons.language),
      title: Text(l10n.settingsLanguage),
      subtitle: Text(chosen?.nativeName ?? l10n.settingsLanguageSystemDefault),
      onTap: () => _choose(context, ref),
    );
  }
}

class _ChoiceOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: selected ? const Icon(Icons.check) : null,
      selected: selected,
      onTap: onTap,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// Import and remove certificate authorities.
///
/// Trusting the CA rather than individual certificates is what makes a
/// self-hosted server with its own authority usable long-term — Caddy's
/// internal CA, for example, reissues server certificates twice a day.
class _CertificateAuthorities extends ConsumerStatefulWidget {
  const _CertificateAuthorities();

  @override
  ConsumerState<_CertificateAuthorities> createState() =>
      _CertificateAuthoritiesState();
}

class _CertificateAuthoritiesState
    extends ConsumerState<_CertificateAuthorities> {
  bool _busy = false;

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);

    try {
      // Certificate files are not reliably typed by the system picker, so any
      // file is offered and validated after the fact.
      final picked = await FilePicker.pickFile(
        dialogTitle: l10n.caPickerTitle,
        type: FileType.any,
      );

      final path = picked?.path;
      if (path == null) return;

      final imported = await ref.read(trustedCasProvider).import(path);
      if (!mounted) return;

      // Importing the server's authority is the other way a screen stuck on an
      // untrusted certificate becomes servable again.
      ref.read(tlsTrustGenerationProvider.notifier).state++;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.caNowTrusting(imported.name))),
      );
    } on InvalidCertificateFile catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(describeError(error, l10n))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.caImportFailed(describeError(error, l10n)))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(TrustedCa certificate) async {
    await ref.read(trustedCasProvider).remove(certificate);
    if (mounted) setState(() {});
  }

  void _showDetails(TrustedCa certificate) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(certificate.name),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppLocalizations.of(context).caFingerprint,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            SelectableText(
              certificate.readableFingerprint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context).actionClose),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authorities = ref.read(trustedCasProvider).certificates;
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final certificate in authorities)
          ListTile(
            leading: const Icon(Icons.workspace_premium),
            title: Text(certificate.name),
            subtitle: Text(l10n.caImportedSubtitle),
            onTap: () => _showDetails(certificate),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.actionRemove,
              onPressed: _busy ? null : () => _remove(certificate),
            ),
          ),
        ListTile(
          leading: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_moderator),
          title: Text(l10n.caImport),
          subtitle: Text(l10n.caImportSubtitle),
          onTap: _busy ? null : _import,
        ),
      ],
    );
  }
}

/// Individually accepted certificates, so the pinning is not a one-way door.
class _PinnedCertificates extends ConsumerStatefulWidget {
  const _PinnedCertificates();

  @override
  ConsumerState<_PinnedCertificates> createState() =>
      _PinnedCertificatesState();
}

class _PinnedCertificatesState extends ConsumerState<_PinnedCertificates> {
  @override
  Widget build(BuildContext context) {
    final store = ref.read(trustedCertificatesProvider);
    final hosts = store.accepted.keys.toList()..sort();
    final l10n = AppLocalizations.of(context);

    if (hosts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final host in hosts)
          ListTile(
            leading: const Icon(Icons.verified_user),
            title: Text(host),
            subtitle: Text(l10n.pinnedSubtitle),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.pinnedStopTrusting,
              onPressed: () async {
                await store.forget(host);
                if (mounted) setState(() {});
              },
            ),
          ),
      ],
    );
  }
}
