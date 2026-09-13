import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:graphql/client.dart';

import 'capabilities.dart';
import 'models.dart';
import 'queries.dart';
import 'session.dart';

/// Raised when the server rejects our credentials and the user must sign in again.
class UnauthorizedException implements Exception {
  const UnauthorizedException();

  @override
  String toString() => 'Your sign-in is no longer accepted.';
}

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

class LoginFailure implements Exception {
  final String message;
  const LoginFailure(this.message);

  @override
  String toString() => message;
}

/// The host presented a certificate the device does not trust — typical of a
/// self-hosted instance behind a private certificate authority. Carries the
/// endpoint so the UI can show the user which certificate to inspect.
class CertificateNotTrustedException implements Exception {
  final Uri endpoint;
  const CertificateNotTrustedException(this.endpoint);

  @override
  String toString() =>
      "The certificate presented by ${endpoint.host} is not trusted.";
}

/// The graphql package defaults to a 5 second request timeout, which a
/// self-hosted instance blows past on the heavier queries — face groups, a
/// 200-item timeline page, or a cluster holding hundreds of media.
const _requestTimeout = Duration(seconds: 60);

class PhotoviewClient {
  final Session session;
  final GraphQLClient _client;

  PhotoviewClient(this.session)
    : _client = GraphQLClient(
        link: HttpLink(
          session.endpoint.toString(),
          defaultHeaders: session.headers,
        ),
        cache: GraphQLCache(),
        queryRequestTimeout: _requestTimeout,
        defaultPolicies: DefaultPolicies(
          query: Policies(fetch: FetchPolicy.networkOnly),
          mutate: Policies(fetch: FetchPolicy.networkOnly),
        ),
      );

  // ---------------------------------------------------------------- login

  /// Signs in against [instance], trying `/graphql` and falling back to
  /// `/api/graphql` the way the server is commonly deployed behind a prefix.
  static Future<Session> login({
    required String instance,
    required String username,
    required String password,
  }) async {
    final bases = candidateBases(instance);
    if (bases.isEmpty) {
      throw const LoginFailure('Invalid instance URL');
    }

    final candidates = [
      for (final base in bases) ...[
        base.resolve('graphql'),
        if (!base.pathSegments.contains('api')) base.resolve('api/graphql'),
      ],
    ];

    return attemptCandidates(
      candidates,
      (endpoint) => _authorize(
        endpoint: endpoint,
        username: username,
        password: password,
      ),
    );
  }

  /// Tries each candidate endpoint in turn until one signs in.
  ///
  /// Separate from [login] so the stopping rules can be tested without a
  /// server: which failures are worth trying the next candidate for is a
  /// security property, not a detail.
  @visibleForTesting
  static Future<Session> attemptCandidates(
    List<Uri> candidates,
    Future<Session> Function(Uri endpoint) authorize,
  ) async {
    Object? lastError;

    for (final endpoint in candidates) {
      try {
        return await authorize(endpoint);
      } on LoginFailure {
        // The server answered and refused the credentials — no point retrying
        // the other path prefix.
        rethrow;
      } on CertificateNotTrustedException {
        // Stop here rather than work down to the plain-HTTP candidate. A bare
        // host is tried over HTTPS first, so continuing would send the
        // password — and later the token — in the clear precisely when the
        // certificate looked suspicious. The user is asked about the
        // certificate instead, and can still type an explicit http:// address
        // if that is what they meant.
        rethrow;
      } catch (error) {
        lastError = error;
      }
    }

    throw LoginFailure(_describe(lastError));
  }

  static Future<Session> _authorize({
    required Uri endpoint,
    required String username,
    required String password,
  }) async {
    final client = GraphQLClient(
      link: HttpLink(endpoint.toString()),
      cache: GraphQLCache(),
      queryRequestTimeout: _requestTimeout,
    );

    final result = await client.mutate(
      MutationOptions(
        document: gql(authorizeUserMutation),
        variables: {'username': username, 'password': password},
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );

    if (result.hasException) {
      if (_causeOf(result.exception!) is TlsException) {
        throw CertificateNotTrustedException(endpoint);
      }
      throw ApiException(_describe(result.exception));
    }

    final auth = result.data?['authorizeUser'] as Map<String, dynamic>?;
    if (auth == null) {
      throw const ApiException('No data returned from server');
    }

    final token = auth['token'] as String?;
    if (auth['success'] != true || token == null) {
      throw LoginFailure(auth['status'] as String? ?? 'Login failed');
    }

    return Session(endpoint: endpoint, token: token);
  }

  /// Bases to try for what the user typed.
  ///
  /// A bare host like `192.168.0.47:8080` gets both schemes, because a
  /// self-hosted instance is as likely to be plain HTTP on a LAN as HTTPS.
  /// An explicit scheme is taken at face value.
  @visibleForTesting
  static List<Uri> candidateBases(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    if (text.contains('://')) {
      final uri = _normalizeBase(text);
      return uri == null ? const [] : [uri];
    }

    return [
      _normalizeBase('https://$text'),
      _normalizeBase('http://$text'),
    ].whereType<Uri>().toList();
  }

  /// Guarantees a trailing slash so [Uri.resolve] appends rather than replaces
  /// the final path segment.
  static Uri? _normalizeBase(String raw) {
    final text = raw.endsWith('/') ? raw : '$raw/';

    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;

    return uri;
  }

  /// Digs the transport-level cause out of gql's wrapping.
  static Object? _causeOf(Object error) {
    if (error is OperationException) {
      final link = error.linkException;
      return link == null ? error : (link.originalException ?? link);
    }
    if (error is LinkException) return error.originalException ?? error;
    return error;
  }

  static String _describe(Object? error) {
    if (error is OperationException) {
      // What the server said beats how the transport failed: a non-200 with a
      // GraphQL body would otherwise be reported as an HTTP status.
      final errors = graphqlErrorsOf(error);
      if (errors.isNotEmpty) return errors.map((e) => e.message).join(', ');

      final link = error.linkException;
      if (link != null) return _describeLink(link);
    }
    if (error is LinkException) return _describeLink(error);
    return _describeCause(error);
  }

  static String _describeLink(LinkException link) {
    if (link is ServerException) {
      final errors = link.parsedResponse?.errors;
      if (errors != null && errors.isNotEmpty) {
        return errors.map((e) => e.message).join(', ');
      }

      // No body at all — the connection may never have produced one. Falling
      // through to toString() here would show the user gql's internal
      // representation, so say what little is known instead.
      final cause = link.originalException;
      final status = link.statusCode;
      if (cause == null) {
        return status == null
            ? 'The server did not answer the request.'
            : 'The server returned HTTP $status.';
      }
    }
    return _describeCause(link.originalException ?? link);
  }

  /// Names the underlying cause. Collapsing everything into one "could not
  /// reach the server" hides the two failures self-hosted instances actually
  /// hit: an untrusted certificate, and a URL that is not the GraphQL endpoint.
  static String _describeCause(Object? error) {
    if (error is TlsException) {
      return "The server's certificate is not trusted "
          '(${error.osError?.message ?? error.message}). Self-hosted instances '
          'often use a private certificate authority.';
    }
    if (error is SocketException) {
      return 'Could not reach the server: ${error.message}';
    }
    if (error is FormatException) {
      return 'The server did not return GraphQL. Check the instance URL.';
    }
    return error?.toString() ?? 'Unknown error';
  }

  // ------------------------------------------------------------- querying

  Future<Map<String, dynamic>> _query(
    String document, [
    Map<String, dynamic> variables = const {},
  ]) async {
    final result = await _client.query(
      QueryOptions(document: gql(document), variables: variables),
    );
    return _unwrap(result);
  }

  /// Runs a mutation, exactly once.
  ///
  /// Queries are safe to repeat, mutations are not, and the difference is not
  /// visible at the call site once a failure has been turned into an
  /// exception — so the rule lives here: **a failed mutation is never retried
  /// automatically**, a timeout included. A timeout says nothing about whether
  /// the server carried the change out; retrying would risk doing it twice,
  /// and the second request runs to completion even when the server
  /// deduplicates the work. Retrying is the user's decision.
  Future<Map<String, dynamic>> _mutate(
    String document, [
    Map<String, dynamic> variables = const {},
  ]) async {
    final result = await _client.mutate(
      MutationOptions(document: gql(document), variables: variables),
    );
    return _unwrap(result);
  }

  Map<String, dynamic> _unwrap(QueryResult result) {
    if (result.hasException) {
      final exception = result.exception!;

      // Order matters. A rejected sign-in is decided first, because it is the
      // only outcome that ends the session; a missing field is decided next,
      // so a schema mismatch is reported as such instead of reaching the user
      // as a raw `Cannot query field …`; anything else is generic.
      if (isUnauthorized(exception)) throw const UnauthorizedException();

      final unsupported = unsupportedFieldException(exception);
      if (unsupported != null) throw unsupported;

      throw ApiException(_describe(exception));
    }

    final data = result.data;
    if (data == null) throw const ApiException('No data returned from server');

    return data;
  }

  /// Whether [exception] means the sign-in is no longer accepted, as opposed to
  /// any other failure.
  ///
  /// This is the decision that signs the user out, so the two cases it must
  /// not confuse are a rejected token and a server that is merely unreachable
  /// or broken. A timeout, a socket error and a 5xx all fall through to
  /// [ApiException] and leave the session alone.
  @visibleForTesting
  static bool isUnauthorized(OperationException exception) {
    final link = exception.linkException;
    if (link is ServerException) {
      final status = link.statusCode;
      // 403 counts as well as 401. This server checks authorization before it
      // validates the query, so a request carrying a stale token comes back as
      // either, depending on how the rejection is raised.
      if (status == 401 || status == 403) return true;
    }

    return graphqlErrorsOf(exception).any(_isAuthError);
  }

  /// Every GraphQL error in [exception], from both places they can hide.
  ///
  /// `graphqlErrors` is only populated for a 200 response. When the server
  /// answers with a non-200 status it still returns a GraphQL body, and those
  /// errors arrive inside the [ServerException]'s parsed response instead.
  /// Reading only the first list reports the HTTP status as though it were a
  /// transport failure and loses what the server actually said.
  @visibleForTesting
  static List<GraphQLError> graphqlErrorsOf(OperationException exception) {
    final link = exception.linkException;
    final parsed = link is ServerException ? link.parsedResponse?.errors : null;

    return [...exception.graphqlErrors, ...?parsed];
  }

  /// The first "this field does not exist" error in [exception], if any.
  @visibleForTesting
  static UnsupportedFieldException? unsupportedFieldException(
    OperationException exception,
  ) {
    for (final error in graphqlErrorsOf(exception)) {
      final named = unsupportedFieldAndTypeIn(error.message);
      if (named != null) {
        return UnsupportedFieldException(
          field: named.field,
          type: named.type,
        );
      }
    }

    return null;
  }

  /// Asks the server which of the newer features it has.
  ///
  /// Deliberately does not go through [_unwrap]: a probe must never be able to
  /// sign the user out. Field-level authorization errors arrive inside an
  /// otherwise successful response, so running probes through the normal path
  /// would let a query about, say, the scanner queue end a perfectly good
  /// session for a non-admin. An unanswerable probe leaves the capability
  /// [CapabilityState.unknown] and the next real request settles the session
  /// question on its own.
  Future<Map<Capability, CapabilityState>> probeCapabilities() async {
    final batch = await _probe(capabilityProbeDocument);
    var found = readProbe(data: batch.data, errorMessages: batch.messages);

    // Whatever the batch could not settle is asked again on its own, so one
    // suppressed or truncated error cannot leave a whole group unknown.
    for (final capability in ServerCapabilities(found).unresolved) {
      final single = await _probe(singleCapabilityProbeDocument(capability));
      found = {
        ...found,
        ...readProbe(data: single.data, errorMessages: single.messages),
      };
    }

    return found;
  }

  Future<({Map<String, dynamic>? data, List<String> messages})> _probe(
    String document,
  ) async {
    final result = await _client.query(
      QueryOptions(
        document: gql(document),
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );

    final exception = result.exception;

    return (
      data: result.data,
      messages: exception == null
          ? const <String>[]
          : graphqlErrorsOf(exception).map((e) => e.message).toList(),
    );
  }

  static bool _isAuthError(GraphQLError error) {
    final message = error.message.toLowerCase();
    return message.contains('unauthorized') ||
        message.contains('not authorized') ||
        message.contains('invalid token');
  }

  // -------------------------------------------------------------- methods

  Future<List<TimelineMedia>> timeline({
    required int limit,
    required int offset,
  }) async {
    final data = await _query(timelineQuery, {
      'limit': limit,
      'offset': offset,
    });
    return (data['myTimeline'] as List<dynamic>? ?? const [])
        .map((e) => TimelineMedia.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<AlbumItem>> myAlbums() async {
    final data = await _query(myAlbumsQuery);
    return (data['myAlbums'] as List<dynamic>? ?? const [])
        .map((e) => AlbumItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AlbumPage> album({
    required String albumId,
    required int limit,
    required int offset,
  }) async {
    final data = await _query(singleAlbumQuery, {
      'albumID': albumId,
      'limit': limit,
      'offset': offset,
    });

    final album = data['album'] as Map<String, dynamic>?;
    if (album == null) throw const ApiException('Album not found');

    return AlbumPage(
      title: album['title'] as String? ?? '',
      media: (album['media'] as List<dynamic>? ?? const [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      subAlbums: (album['subAlbums'] as List<dynamic>? ?? const [])
          .map((e) => AlbumItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<FaceGroup>> faceGroups({
    required int limit,
    required int offset,
  }) async {
    final data = await _query(myFacesThumbnailsQuery, {
      'limit': limit,
      'offset': offset,
    });
    return (data['myFaceGroups'] as List<dynamic>? ?? const [])
        .map((e) => FaceGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<MediaItem>> personMedia(String faceGroupId) async {
    final data = await _query(singlePersonQuery, {'faceGroupID': faceGroupId});
    final group = data['faceGroup'] as Map<String, dynamic>?;

    return (group?['imageFaces'] as List<dynamic>? ?? const [])
        .map((e) => (e as Map<String, dynamic>)['media'])
        .whereType<Map<String, dynamic>>()
        .map(MediaItem.fromJson)
        .toList();
  }

  Future<List<PlacesMarker>> mediaGeoJson() async {
    final data = await _query(mediaGeoJsonQuery);
    final raw = data['myMediaGeoJson'];
    if (raw == null) return const [];

    // The server returns the FeatureCollection as a JSON scalar, which may
    // arrive either already decoded or as an encoded string. A JSON scalar is
    // valid too, so the shape is checked rather than cast: a bare cast throws
    // a TypeError, which is not an ApiException and would reach the places
    // screen as a raw Dart error instead of a readable message.
    final Object? decoded;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw const ApiException(
          'The server returned map data that is not valid JSON.',
        );
      }
    } else {
      decoded = raw;
    }

    if (decoded is! Map<String, dynamic>) {
      throw const ApiException(
        'The server returned map data in an unexpected shape.',
      );
    }
    final geojson = decoded;

    return (geojson['features'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PlacesMarker.fromFeature)
        .whereType<PlacesMarker>()
        .toList();
  }

  Future<List<MediaItem>> mediaList(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final data = await _query(placesClusterDetailsQuery, {'ids': ids});
    return (data['mediaList'] as List<dynamic>? ?? const [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MediaDetails> mediaDetails(String mediaId) async {
    final data = await _query(mediaDetailsQuery, {'mediaID': mediaId});
    final media = data['media'] as Map<String, dynamic>?;
    if (media == null) throw const ApiException('Media not found');
    return MediaDetails.fromJson(media);
  }

  /// Searches, with [limitMedia] and [limitAlbums] passed through as given.
  ///
  /// Null leaves them out and the server applies its own default of ten each;
  /// zero means unlimited. Neither is decided here — the caller knows whether
  /// the user set a limit.
  Future<SearchResults> search(
    String query, {
    int? limitMedia,
    int? limitAlbums,
  }) async {
    final data = await _query(mediaSearchQuery, {
      'query': query,
      'limitMedia': limitMedia,
      'limitAlbums': limitAlbums,
    });

    final search = data['search'] as Map<String, dynamic>?;
    if (search == null) return SearchResults(query: query);
    return SearchResults.fromJson(search);
  }

  /// Children of each album in [albumIds], keyed by album id.
  ///
  /// Ids are deduplicated before asking: a live instance echoes a repeated id
  /// as a repeated entry, so sending duplicates would pay for the same album
  /// twice and then overwrite one answer with the other.
  ///
  /// An album that is missing from the answer, or present with no children,
  /// both mean the same thing to the caller — the server filters out ids the
  /// user may not see, and a leaf simply has none. Both come back as an empty
  /// list rather than as an error.
  Future<Map<String, List<AlbumItem>>> albumTreeChildren(
    List<String> albumIds,
  ) async {
    final unique = albumIds.toSet().toList();
    if (unique.isEmpty) return {};

    final data = await _query(albumTreeChildrenQuery, {'albumIds': unique});
    final entries = data['albumTreeChildren'] as List<dynamic>? ?? const [];

    final result = {for (final id in unique) id: <AlbumItem>[]};

    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) continue;

      final id = entry['albumId']?.toString();
      if (id == null) continue;

      result[id] = (entry['children'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AlbumItem.fromJson)
          .toList();
    }

    return result;
  }

  Future<List<ScannerJob>> scannerQueue() async {
    final data = await _query(scannerQueueStatusQuery);

    return (data['scannerQueueStatus'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ScannerJob.fromJson)
        .toList();
  }

  /// Queues [albumId] and its sub-albums, returning the server's message.
  ///
  /// Goes through [_mutate], so it is never retried automatically: the server
  /// deduplicates queued albums, but a repeated request still runs to
  /// completion, and a timeout says nothing about whether the first one was
  /// accepted.
  Future<String?> scanAlbum(String albumId) async {
    final data = await _mutate(scanAlbumMutation, {'albumId': albumId});
    final result = data['scanAlbum'] as Map<String, dynamic>?;

    if (result?['success'] != true) {
      throw ApiException(
        result?['message'] as String? ?? 'The server refused to start a scan',
      );
    }

    return result?['message'] as String?;
  }

  /// Cancels one album's job. False means there was nothing to cancel — which
  /// is the normal answer for an album whose sub-albums are the queued ones.
  Future<bool> cancelScanJob(String albumId) async {
    final data = await _mutate(cancelScanJobMutation, {'albumId': albumId});
    return data['cancelScanJob'] as bool? ?? false;
  }

  /// Cancels everything the user may cancel, returning how many jobs that was.
  Future<int> cancelAllScanJobs() async {
    final data = await _mutate(cancelAllScanJobsMutation);
    return data['cancelAllScanJobs'] as int? ?? 0;
  }

  Future<UserPreferences> userPreferences() async {
    final data = await _query(userPreferencesQuery);
    final preferences = data['myUserPreferences'] as Map<String, dynamic>?;
    if (preferences == null) return const UserPreferences();
    return UserPreferences.fromJson(preferences);
  }

  /// Writes the whole preferences record.
  ///
  /// Both fields are always sent because the server replaces rather than
  /// patches: measured against a live instance, writing only the search limit
  /// reset a `language` of `English` to null. Callers therefore pass what they
  /// want the record to *be*, not what they want to change — which is also how
  /// the search limit is cleared, since a negative value is refused outright.
  Future<UserPreferences> changeUserPreferences({
    String? language,
    int? searchResultLimit,
  }) async {
    final data = await _mutate(changeUserPreferencesMutation, {
      'language': language,
      'searchResultLimit': searchResultLimit,
    });

    final preferences =
        data['changeUserPreferences'] as Map<String, dynamic>?;
    if (preferences == null) return const UserPreferences();
    return UserPreferences.fromJson(preferences);
  }

  Future<void> shareMedia(String mediaId) =>
      _mutate(shareMediaMutation, {'id': mediaId});

  Future<void> deleteShareToken(String token) =>
      _mutate(deleteShareTokenMutation, {'token': token});
}

class AlbumPage {
  final String title;
  final List<MediaItem> media;
  final List<AlbumItem> subAlbums;

  const AlbumPage({
    required this.title,
    required this.media,
    required this.subAlbums,
  });
}
