import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:photoview/api/client.dart';
import 'package:photoview/api/media_files.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/api/session.dart';

final _session = Session(
  endpoint: Uri.parse('http://host:8081/api/graphql'),
  token: 'secret-token',
  username: 'admin',
);

MediaDownload _download(String title, String url) =>
    MediaDownload(title: title, url: url, width: 1, height: 1, fileSize: 1);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('media_files_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  MediaFileFetcher fetcherWith(MockClientStreamHandler handler) =>
      MediaFileFetcher(
        newClient: () => MockClient.streaming(handler),
        directory: () async => temp,
      );

  http.StreamedResponse respond(int status, List<List<int>> chunks) =>
      http.StreamedResponse(Stream.fromIterable(chunks), status);

  group('MediaFileFetcher.fetch', () {
    test('streams the file through the signed-in session', () async {
      late http.BaseRequest seen;
      final fetcher = fetcherWith((request, _) async {
        seen = request;
        return respond(200, [
          [1, 2, 3],
          [4, 5],
        ]);
      });

      final file = await fetcher.fetch(
        _session,
        '/api/photo/a_XYZ.jpg',
        fileName: 'a.jpg',
      );

      expect(file.readAsBytesSync(), [1, 2, 3, 4, 5]);
      expect(file.path, endsWith('a.jpg'));
      expect(seen.url.toString(), 'http://host:8081/api/photo/a_XYZ.jpg');
      expect(seen.headers['Cookie'], 'auth-token=secret-token');
    });

    test('an expired sign-in is reported as such', () async {
      final fetcher = fetcherWith((_, _) async => respond(401, []));

      await expectLater(
        fetcher.fetch(_session, '/a.jpg', fileName: 'a.jpg'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('a refused file is a refusal, not a rejected sign-in', () async {
      final fetcher = fetcherWith((_, _) async => respond(403, []));

      await expectLater(
        fetcher.fetch(_session, '/a.jpg', fileName: 'a.jpg'),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('an error says what the server said, and writes nothing', () async {
      // Measured: the album download answers an album without matching media
      // with HTTP 400 and the plain text "no media found". Saving that as the
      // photo is exactly what the web version used to do.
      final fetcher = fetcherWith(
        (_, _) async => respond(400, [utf8.encode('no media found\n')]),
      );

      await expectLater(
        fetcher.fetch(_session, '/a.jpg', fileName: 'a.jpg'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            allOf(contains('400'), contains('no media found')),
          ),
        ),
      );
      expect(
        temp.listSync(recursive: true).whereType<File>(),
        isEmpty,
        reason: 'no file for an error response',
      );
    });

    test('a transfer that breaks off leaves no partial file behind', () async {
      final fetcher = fetcherWith((_, _) async {
        final controller = StreamController<List<int>>();
        controller
          ..add([1, 2, 3])
          ..addError(const SocketException('connection reset'))
          ..close();
        return http.StreamedResponse(controller.stream, 200);
      });

      await expectLater(
        fetcher.fetch(_session, '/a.jpg', fileName: 'a.jpg'),
        throwsA(isA<SocketException>()),
      );
      expect(temp.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  });

  group('downloadFileName', () {
    test('the original keeps its name in the library', () {
      // Not the storage name with its random suffix.
      expect(
        downloadFileName(
          'screenshots_01.jpg',
          _download('Original', '/api/photo/screenshots_01_PBXdCHRa.jpg'),
        ),
        'screenshots_01.jpg',
      );
    });

    test('the extension follows the file actually served', () {
      expect(
        downloadFileName('IMG_0001.HEIC', _download('High-res', '/api/photo/x.jpg')),
        'IMG_0001_high-res.jpg',
      );
      expect(
        downloadFileName('holiday', _download('Original', '/api/photo/holiday_Q.jpg')),
        'holiday.jpg',
      );
      expect(
        downloadFileName('IMG.PNG', _download('Original', '/api/photo/img.jpg')),
        'IMG.jpg',
      );
    });

    test('other renditions name their purpose, so they do not overwrite it', () {
      expect(
        downloadFileName(
          'screenshots_01.jpg',
          _download('Small', '/api/photo/thumbnail_screenshots_01_jpg_xD.jpg'),
        ),
        'screenshots_01_small.jpg',
      );
    });

    test('a title cannot turn the name into a path', () {
      final name = downloadFileName(
        '../../etc/passwd.jpg',
        _download('Original', '/api/photo/p.jpg'),
      );

      expect(name, isNot(contains('/')));
      expect(name, isNot(startsWith('.')));
      expect(name, endsWith('.jpg'));
    });

    test('an empty title still gives a usable name', () {
      expect(downloadFileName('', _download('Original', '/api/photo/p.jpg')), 'photo.jpg');
    });
  });
}
