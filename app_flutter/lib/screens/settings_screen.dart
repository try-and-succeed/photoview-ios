import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/capabilities.dart';
import '../api/trusted_cas.dart';
import '../state/auth.dart';
import '../state/capabilities.dart';
import 'scanner_screen.dart';
import '../util/image_cache.dart';
import '../widgets/insecure_notice.dart';
import '../widgets/search_limit_field.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (session != null)
            ListTile(
              leading: const Icon(Icons.dns),
              title: const Text('Connected instance'),
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
            title: const Text('Switch server'),
            subtitle: const Text('Keeps this sign-in for one-tap return'),
            onTap: () => ref.read(authProvider.notifier).switchServer(),
          ),
          if (session != null &&
              ref.watch(hasCapabilityProvider(Capability.scanner))) ...[
            const Divider(),
            const _SectionHeader('Library'),
            ListTile(
              leading: const Icon(Icons.radar),
              title: const Text('Scanner'),
              subtitle: const Text('What the server is indexing right now'),
              onTap: () => showScanner(Navigator.of(context)),
            ),
          ],
          if (session != null) ...[
            const Divider(),
            const _SectionHeader('Search'),
            const SearchLimitField(),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Re-check server features'),
              subtitle: const Text(
                'After updating your Photoview server',
              ),
              onTap: () async {
                await ref.read(recheckCapabilitiesProvider)();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Checking your server again…')),
                );
              },
            ),
          ],
          const Divider(),
          const _SectionHeader('Security'),
          const _CertificateAuthorities(),
          const _PinnedCertificates(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('Clear image cache'),
            onTap: () async {
              await clearImageCache();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Image cache cleared')),
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
              'Log out',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: const Text('Forgets this saved sign-in'),
            onTap: () => ref.read(authProvider.notifier).logOut(),
          ),
        ],
      ),
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
    setState(() => _busy = true);

    try {
      // Certificate files are not reliably typed by the system picker, so any
      // file is offered and validated after the fact.
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Select a CA certificate',
        type: FileType.any,
      );

      final path = picked?.path;
      if (path == null) return;

      final imported = await ref.read(trustedCasProvider).import(path);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Now trusting ${imported.name}')),
      );
    } on InvalidCertificateFile catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
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
              'SHA-256 fingerprint',
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
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authorities = ref.read(trustedCasProvider).certificates;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final certificate in authorities)
          ListTile(
            leading: const Icon(Icons.workspace_premium),
            title: Text(certificate.name),
            subtitle: const Text('Certificate authority you imported'),
            onTap: () => _showDetails(certificate),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
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
          title: const Text('Import certificate authority'),
          subtitle: const Text(
            'A .pem or .crt file — for a server with its own CA',
          ),
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

    if (hosts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final host in hosts)
          ListTile(
            leading: const Icon(Icons.verified_user),
            title: Text(host),
            subtitle: const Text('Single certificate you accepted'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Stop trusting',
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
