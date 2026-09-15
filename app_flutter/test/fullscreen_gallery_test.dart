import 'package:flutter_test/flutter_test.dart';
import 'package:photoview/api/models.dart';
import 'package:photoview/widgets/fullscreen_gallery.dart';

const _thumbnail = Thumbnail(url: '/api/photo/thumbnail_a.jpg', width: 1024, height: 576);
const _full = Thumbnail(url: '/api/photo/a.jpg', width: 1920, height: 1080);

const _item = MediaItem(id: '4', type: MediaType.photo, thumbnail: _thumbnail);

MediaDetails _details({Thumbnail? highRes}) =>
    MediaDetails(media: _item, title: 'a.jpg', highRes: highRes);

void main() {
  group('galleryLayers', () {
    test('shows the thumbnail while the details are still loading', () {
      expect(galleryLayers(_item, null), [_thumbnail]);
    });

    test('layers the full image over the thumbnail once it is known', () {
      // The point of this stage: the gallery used to show only the thumbnail,
      // at most 1024 px, even full screen and zoomed in.
      expect(galleryLayers(_item, _details(highRes: _full)), [_thumbnail, _full]);
    });

    test('adds nothing when the server names no full image', () {
      expect(galleryLayers(_item, _details()), [_thumbnail]);
    });

    test('does not load the same file twice as two layers', () {
      expect(galleryLayers(_item, _details(highRes: _thumbnail)), [_thumbnail]);
    });
  });

  test('decodes full images no larger than twice a phone screen and then some',
      () {
    // An original can be tens of megapixels; the gallery keeps neighbouring
    // pages alive. The limit must stay well above screen size for zoom.
    expect(fullImageDecodeLimit, inInclusiveRange(2048, 4096));
  });
}
