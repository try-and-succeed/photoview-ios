import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/session.dart';
import '../api/trusted_certificates.dart';
import '../l10n/app_localizations.dart';
import '../l10n/error_messages.dart';
import '../state/auth.dart';
import '../widgets/certificate_dialog.dart';
import '../widgets/insecure_notice.dart';
import '../widgets/password_field.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _instance = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  bool _connecting = false;
  bool _addingServer = false;
  String? _error;

  /// Set once the fields have been filled from an expired session, so a later
  /// rebuild does not overwrite what the user has typed since.
  bool _prefilled = false;

  @override
  void dispose() {
    _instance.dispose();
    _username.dispose();
    _password.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _login() => ref
      .read(authProvider.notifier)
      .login(
        instance: _instance.text,
        username: _username.text,
        password: _password.text,
      );

  Future<void> _connect() async {
    if (_connecting) return;

    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      await _login();
    } on CertificateNotTrustedException catch (error) {
      await _offerCertificate(error.endpoint);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _openSaved(SavedServer server) async {
    if (_connecting) return;

    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      // Checked before opening, not after. Reopening a saved server makes no
      // request of its own, so a certificate problem would otherwise surface
      // pages later as an error on the timeline — with no way to accept the
      // certificate, because the only place that asks is this screen. Pinned
      // certificates expire: Caddy's internal CA issues twelve-hour leaves, so
      // a server that worked this morning presents a new one by evening.
      if (!await _certificateAccepted(server.endpoint)) return;

      await ref.read(authProvider.notifier).openSaved(server);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// Whether [endpoint] can be trusted, asking the user if it is new or has
  /// changed.
  Future<bool> _certificateAccepted(Uri endpoint) async {
    if (endpoint.scheme != 'https') return true;

    // Null means the certificate validates on its own — a public CA, or one
    // the user imported — or that the host cannot be reached at all. Neither
    // is a question for the user here; an unreachable host reports itself
    // through the sign-in that follows.
    final certificate = await probeCertificate(endpoint);

    // Gone while the probe was out: nothing further should be opened on
    // behalf of a screen the user has already left.
    if (!mounted) return false;
    if (certificate == null) return true;

    final store = ref.read(trustedCertificatesProvider);
    final pinned = store.accepted[certificate.host];
    if (pinned == certificate.sha256) return true;

    final accepted = await showCertificateDialog(
      context,
      certificate,
      replacesTrusted: pinned != null,
    );
    if (!mounted) return false;

    if (!accepted) {
      setState(
        () => _error = AppLocalizations.of(context).certificateNotAcceptedFor(certificate.host),
      );
      return false;
    }

    await store.trust(certificate);
    ref.read(tlsTrustGenerationProvider.notifier).state++;
    return true;
  }

  Future<void> _forget(SavedServer server) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.welcomeForgetServerTitle(server.label)),
        content: Text(l10n.welcomeForgetServerBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionForget),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await ref.read(authProvider.notifier).forget(server);
  }

  /// Shows the certificate the host presented and, if the user accepts it,
  /// pins it and retries the sign-in.
  Future<void> _offerCertificate(Uri endpoint) async {
    final certificate = await probeCertificate(endpoint);
    if (!mounted) return;

    if (certificate == null) {
      setState(
        () => _error = AppLocalizations.of(context).certificateCouldNotRead(endpoint.host),
      );
      return;
    }

    final accepted = await showCertificateDialog(context, certificate);
    if (!mounted) return;

    if (!accepted) {
      setState(
        () => _error = AppLocalizations.of(context).certificateNotAcceptedFor(certificate.host),
      );
      return;
    }

    await ref.read(trustedCertificatesProvider).trust(certificate);
    ref.read(tlsTrustGenerationProvider.notifier).state++;

    try {
      await _login();
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(
      () => _error = describeError(error, AppLocalizations.of(context)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(savedServersProvider).valueOrNull ?? const [];
    final expired = ref.watch(expiredSessionProvider);

    // An expired session drops straight to the form with its details filled
    // in, so only the password has to be typed.
    if (expired != null && !_prefilled) {
      _prefilled = true;
      _addingServer = true;
      _instance.text = expired.instanceUrl.toString();
      _username.text = expired.username;
    }

    final showForm = servers.isEmpty || _addingServer;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(subtitle: showForm
                      ? l10n.welcomeConnectSubtitle
                      : l10n.welcomeChooseServer),
                  if (expired != null) _ExpiredNotice(session: expired),
                  if (!showForm) ...[
                    for (final server in servers)
                      _SavedServerTile(
                        server: server,
                        enabled: !_connecting,
                        onOpen: () => _openSaved(server),
                        onForget: () => _forget(server),
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _connecting
                          ? null
                          : () => setState(() => _addingServer = true),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.welcomeAnotherServer),
                    ),
                  ] else
                    ..._formFields(context, canGoBack: servers.isNotEmpty),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _formFields(BuildContext context, {required bool canGoBack}) {
    final l10n = AppLocalizations.of(context);
    return [
    TextField(
      controller: _instance,
      decoration: InputDecoration(
        labelText: l10n.welcomeInstanceLabel,
        hintText: 'https://example.com',
        border: OutlineInputBorder(),
      ),
      keyboardType: TextInputType.url,
      autocorrect: false,
      textInputAction: TextInputAction.next,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _usernameFocus.requestFocus(),
    ),
    if (InsecureConnectionNotice.riskOfText(_instance.text) !=
        InsecureConnectionRisk.none) ...[
      const SizedBox(height: 12),
      InsecureConnectionNotice(
        host: InsecureConnectionNotice.hostOfText(_instance.text),
        risk: InsecureConnectionNotice.riskOfText(_instance.text),
      ),
    ],
    const SizedBox(height: 16),
    TextField(
      controller: _username,
      focusNode: _usernameFocus,
      decoration: InputDecoration(
        labelText: l10n.loginUsername,
        border: OutlineInputBorder(),
      ),
      autocorrect: false,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => _passwordFocus.requestFocus(),
    ),
    const SizedBox(height: 16),
    PasswordField(
      controller: _password,
      focusNode: _passwordFocus,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => _connect(),
    ),
    const SizedBox(height: 24),
    FilledButton(
      onPressed: _connecting ? null : _connect,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      child: _connecting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(l10n.welcomeConnect),
    ),
    if (canGoBack) ...[
      const SizedBox(height: 8),
      TextButton(
        onPressed: _connecting
            ? null
            : () => setState(() {
                _addingServer = false;
                _error = null;
              }),
        child: Text(l10n.welcomeBackToSavedServers),
      ),
    ],
  ];
  }
}

class _Header extends StatelessWidget {
  final String subtitle;

  const _Header({required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Icon(Icons.photo_library, size: 88, color: theme.colorScheme.primary),
        const SizedBox(height: 20),
        Text(
          AppLocalizations.of(context).welcomeTitle,
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _ExpiredNotice extends StatelessWidget {
  final Session session;

  const _ExpiredNotice({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppLocalizations.of(context).welcomeSessionExpired(
                session.instanceUrl.host,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedServerTile extends StatelessWidget {
  final SavedServer server;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onForget;

  const _SavedServerTile({
    required this.server,
    required this.enabled,
    required this.onOpen,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final username = server.username;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        enabled: enabled,
        leading: Icon(Icons.dns, color: theme.colorScheme.primary),
        title: Text(server.label),
        subtitle: Text(
          username.isEmpty ? server.endpoint.scheme : '$username · ${server.endpoint.scheme}',
        ),
        onTap: enabled ? onOpen : null,
        trailing: IconButton(
          icon: const Icon(Icons.close),
          tooltip: AppLocalizations.of(context).welcomeForgetServerTooltip,
          onPressed: enabled ? onForget : null,
        ),
      ),
    );
  }
}
