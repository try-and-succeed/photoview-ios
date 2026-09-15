import 'client.dart';

/// A server feature the app can use only if this particular instance has it.
///
/// Photoview instances are self-hosted and updated whenever their owner gets
/// round to it, so the app talks to a spread of versions at once. Introspection
/// is disabled on the server, so the schema cannot simply be read — each
/// feature has to be asked about.
enum Capability {
  /// `UserPreferences.searchResultLimit`, so the search limit can be stored
  /// server-side instead of only on this device.
  searchLimitPreference,

  /// `UserPreferences.showAlbumTree`.
  albumTreePreference,

  /// `albumTreeChildren`, which fetches the children of many albums at once.
  albumTree,

  /// `scannerQueueStatus` and the scan mutations.
  scanner,
}

/// What is known about one capability.
///
/// [unknown] is not a loading state: it is a lasting answer meaning the
/// question could not be settled, usually because the probe was refused. The
/// UI renders it as absent rather than as a spinner, so a feature never
/// flickers into view and out again.
enum CapabilityState { unknown, supported, unsupported }

/// The server does not have a field this app asked for.
///
/// A subclass of [ApiException] on purpose: every existing `catch` on
/// ApiException keeps working, and a raw `Cannot query field …` can no longer
/// reach the user as an error message.
class UnsupportedFieldException extends ApiException {
  /// The field the server rejected, e.g. `albumTreeChildren`.
  final String field;

  /// The GraphQL type it was asked for on, e.g. `Query`. Null when the server
  /// complained about an argument rather than a field.
  final String? type;

  UnsupportedFieldException({required this.field, this.type})
    : super(
        'Your Photoview server does not support this yet '
        '(it has no "$field"${type == null ? '' : ' on $type'}).',
      );

  /// Capabilities this rejection rules out.
  Set<Capability> get ruledOut => capabilitiesNamedBy(field);
}

/// Fields whose absence identifies each capability.
///
/// More than one per capability, because a feature can be missing at two
/// depths: an old server may not have `myUserPreferences` at all, in which
/// case neither preference exists either.
const _identifyingFields = <Capability, Set<String>>{
  Capability.searchLimitPreference: {'searchResultLimit', 'myUserPreferences'},
  Capability.albumTreePreference: {'showAlbumTree', 'myUserPreferences'},
  Capability.albumTree: {'albumTreeChildren'},
  Capability.scanner: {
    'scannerQueueStatus',
    'scanAlbum',
    'cancelScanJob',
    'cancelAllScanJobs',
  },
};

/// Capabilities that a rejection of [field] rules out.
Set<Capability> capabilitiesNamedBy(String field) => {
  for (final entry in _identifyingFields.entries)
    if (entry.value.contains(field)) entry.key,
};

/// The key under which a capability's positive evidence appears in the probe's
/// data, as `topLevelField` and, where it is nested, `withinField`.
const _evidence = <Capability, ({String topLevelField, String? withinField})>{
  Capability.searchLimitPreference: (
    topLevelField: 'myUserPreferences',
    withinField: 'searchResultLimit',
  ),
  Capability.albumTreePreference: (
    topLevelField: 'myUserPreferences',
    withinField: 'showAlbumTree',
  ),
  Capability.albumTree: (topLevelField: 'albumTreeChildren', withinField: null),
  Capability.scanner: (
    topLevelField: 'scannerQueueStatus',
    withinField: null,
  ),
};

/// Asks about every capability in one round trip.
///
/// GraphQL validation reports all offending fields at once, so a single
/// document is enough to learn about several missing features — verified
/// against a live instance, which answered five separate "Cannot query field"
/// errors for one request.
///
/// Takes no variables on purpose. The empty album list is an inline literal so
/// that every probe, batched or single, is a bare document: passing a variable
/// that a document does not declare works on this server but is not something
/// to rely on from an app whose whole job here is to cope with servers that
/// differ.
const capabilityProbeDocument = '''
query photoviewCapabilities {
  myUserPreferences {
    searchResultLimit
    showAlbumTree
  }
  albumTreeChildren(albumIds: []) {
    albumId
  }
  scannerQueueStatus {
    status
  }
}
''';

/// Probes for one capability on its own, for whatever the batch left unclear.
String singleCapabilityProbeDocument(Capability capability) =>
    switch (capability) {
      Capability.searchLimitPreference =>
        'query photoviewCapability { myUserPreferences { searchResultLimit } }',
      Capability.albumTreePreference =>
        'query photoviewCapability { myUserPreferences { showAlbumTree } }',
      Capability.albumTree =>
        'query photoviewCapability '
            '{ albumTreeChildren(albumIds: []) { albumId } }',
      Capability.scanner =>
        'query photoviewCapability { scannerQueueStatus { status } }',
    };

/// What the server said about every capability.
class ServerCapabilities {
  final Map<Capability, CapabilityState> states;

  const ServerCapabilities(this.states);

  static const unknownToAll = ServerCapabilities({});

  CapabilityState operator [](Capability capability) =>
      states[capability] ?? CapabilityState.unknown;

  bool has(Capability capability) =>
      this[capability] == CapabilityState.supported;

  /// Capabilities still to be asked about individually.
  Iterable<Capability> get unresolved => Capability.values.where(
    (c) => this[c] == CapabilityState.unknown,
  );

  ServerCapabilities merge(Map<Capability, CapabilityState> newer) =>
      ServerCapabilities({...states, ...newer});

  /// Forgets that [capability] was supported, after a real call proved it is
  /// not. Lets a wrong "supported" heal itself without waiting for an expiry.
  ServerCapabilities downgrade(Capability capability) =>
      merge({capability: CapabilityState.unsupported});

  @override
  String toString() => 'ServerCapabilities($states)';
}

/// Reads one probe response.
///
/// The safety rule, and the reason this is a function rather than a few lines
/// inline: a capability is only ever marked [CapabilityState.unsupported] when
/// an error names its field, and only marked [CapabilityState.supported] when
/// the data actually carries it. Never the absence of an error — an error
/// limit, a cascade, or an authorization failure that suppresses part of a
/// response would otherwise poison every capability in the batch at once.
Map<Capability, CapabilityState> readProbe({
  Map<String, dynamic>? data,
  List<String> errorMessages = const [],
}) {
  final result = <Capability, CapabilityState>{};

  for (final message in errorMessages) {
    final field = unsupportedFieldIn(message);
    if (field == null) continue;

    for (final capability in capabilitiesNamedBy(field)) {
      result[capability] = CapabilityState.unsupported;
    }
  }

  if (data != null) {
    for (final entry in _evidence.entries) {
      if (result[entry.key] == CapabilityState.unsupported) continue;

      final top = entry.value.topLevelField;
      if (!data.containsKey(top)) continue;

      final nested = entry.value.withinField;
      if (nested == null) {
        result[entry.key] = CapabilityState.supported;
        continue;
      }

      // A null value is a legitimate answer — the live server returns
      // `searchResultLimit: null` when the preference is simply unset — so it
      // is the key that counts as evidence, not the value.
      final container = data[top];
      if (container is Map<String, dynamic> && container.containsKey(nested)) {
        result[entry.key] = CapabilityState.supported;
      }
    }
  }

  return result;
}

/// Matches a server that rejected a field, as opposed to any other error.
///
/// Both wordings taken from a live instance:
///   Cannot query field "albumId" on type "ScannerQueueItem".
///   Unknown argument "showHidden" on field "Query.myAlbums".
final _cannotQueryField = RegExp(
  r'Cannot query field "([^"]+)" on type "([^"]+)"',
);
final _unknownArgument = RegExp(
  r'Unknown argument "([^"]+)" on field "([^"]+)"',
);

/// The field named by [message], or null if it is not a rejection at all.
String? unsupportedFieldIn(String message) =>
    (_cannotQueryField.firstMatch(message) ??
            _unknownArgument.firstMatch(message))
        ?.group(1);

/// The field and type named by [message], for building an exception.
({String field, String? type})? unsupportedFieldAndTypeIn(String message) {
  final field = _cannotQueryField.firstMatch(message);
  if (field != null) {
    return (field: field.group(1)!, type: field.group(2));
  }

  final argument = _unknownArgument.firstMatch(message);
  if (argument != null) {
    // For an argument the second group names the field it sits on, which is
    // not a type — so it is not reported as one.
    return (field: argument.group(1)!, type: null);
  }

  return null;
}
