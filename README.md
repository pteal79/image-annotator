# pteal79/image-annotator

A NativePHP Mobile v4 plugin that opens a full-screen, fully native image annotation editor on iOS (Swift, UIKit) and Android (Kotlin, custom `View`). There is no WebView and no JavaScript.

The user draws freehand lines, straight lines, rectangles and text on an image. Everything stays editable until they save: shapes can be selected, moved, resized, restyled, re-ordered and deleted, with undo and redo for every change. On **Save** the annotations are flattened into a JPEG (quality 0.92, same pixel size as the input) in the app's cache dir, and the path comes back to Laravel as an event.

The plugin only works on local files. It never touches the network.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Events](#events)
- [SuperNative example](#supernative-example)
- [The editor](#the-editor)
- [Behaviour notes](#behaviour-notes)
- [Testing](#testing)
- [License](#license)

## Requirements

- PHP 8.4 or later
- NativePHP Mobile v4 (`nativephp/mobile` `^4.0`)
- iOS 18.2 or later, Android 8.0 (API 26) or later
- No permissions. The plugin only reads the paths you give it and writes to the app's cache dir.

## Installation

```bash
composer require pteal79/image-annotator
```

During development, load it from a local folder with a `path` repository in your app's `composer.json`:

```json
{
    "repositories": [
        { "type": "path", "url": "../packages/pteal79/image-annotator" }
    ],
    "require": {
        "pteal79/image-annotator": "*"
    }
}
```

Register it with NativePHP, then rebuild:

```bash
# Creates app/Providers/NativeServiceProvider.php if you do not have it yet
php artisan vendor:publish --tag=nativephp-plugins-provider

php artisan native:plugin:register pteal79/image-annotator
php artisan native:plugin:validate
php artisan native:install --force
```

The manifest adds one Android activity (`AnnotatorActivity`, not exported). Nothing is added to `Info.plist`.

## Usage

```php
use Pteal79\ImageAnnotator\Facades\ImageAnnotator;

ImageAnnotator::open(
    imagePath: $localPath,            // required: local JPEG/PNG of the current image
    originalPath: $localOriginalPath, // optional: local original; when given, the editor shows Revert
    id: (string) $jobImageId,         // required: echoed back in every event
);
```

- Use named arguments. The PHP signature is `open(string $imagePath, string $id, ?string $originalPath = null): bool`.
- `open()` returns straight away. It returns `true` when the editor is opening, and `false` off-device or when native refused (a refusal still sends `ImageAnnotationFailed`).
- A blank `imagePath` or `id` throws `InvalidArgumentException`. A blank `originalPath` is treated as none.
- Pass images that are ready to use: downscaled to a long edge of at most 4096 px. EXIF orientation is applied when decoding, so the image is drawn and exported upright.

## Events

Every `open()` ends with exactly **one** of these events. The editor is dismissed before the event is sent.

| Event | Payload | Meaning |
|---|---|---|
| `ImageAnnotationSaved` | `id`, `outputPath`, `width`, `height`, `reverted` | The user pressed Save. `outputPath` is a JPEG (quality 0.92) in the cache dir, named `annotated-{id}-{timestamp}.jpg`. `reverted` is true if Revert was used in this session |
| `ImageAnnotationCancelled` | `id` | The user closed without saving |
| `ImageAnnotationFailed` | `id`, `message` | The input could not be loaded, or the editor could not open. `message` is `"already open"` when `open()` was called while an editor was showing |

All three live in `Pteal79\ImageAnnotator\Events`. Your app owns `outputPath` once the event arrives: move or upload it, then delete it.

Save failures do **not** send `ImageAnnotationFailed`. The editor shows "Couldn't save image" and stays open so the user can try again or close.

## SuperNative example

```php
namespace App\NativeComponents;

use Illuminate\Support\Facades\File;
use Native\Mobile\Attributes\On;
use Native\Mobile\Edge\NativeComponent;
use Pteal79\ImageAnnotator\Events\ImageAnnotationCancelled;
use Pteal79\ImageAnnotator\Events\ImageAnnotationFailed;
use Pteal79\ImageAnnotator\Events\ImageAnnotationSaved;
use Pteal79\ImageAnnotator\Facades\ImageAnnotator;

class JobPhoto extends NativeComponent
{
    public int $imageId;

    public function annotate(): void
    {
        ImageAnnotator::open(
            imagePath: storage_path("app/job-images/{$this->imageId}.jpg"),
            originalPath: storage_path("app/job-images/{$this->imageId}-original.jpg"),
            id: (string) $this->imageId,
        );
    }

    #[On(ImageAnnotationSaved::class)]
    public function saved(string $id = '', string $outputPath = '', int $width = 0, int $height = 0, bool $reverted = false): void
    {
        if ($id !== (string) $this->imageId) {
            return;
        }

        File::move($outputPath, storage_path("app/job-images/{$id}.jpg"));
        // Queue the upload here.
    }

    #[On(ImageAnnotationCancelled::class)]
    public function cancelled(string $id = ''): void {}

    #[On(ImageAnnotationFailed::class)]
    public function failed(string $id = '', string $message = ''): void
    {
        // Show $message.
    }
}
```

## The editor

- **Tools:** Select (default), Pen (freehand), Line, Rect and Text.
- **Colour:** red (`#ef4444`) by default, from a palette of red, orange, yellow, green, blue, black and white.
- **Size:** S / M / L / XL (default M). Stroke widths 2 / 4 / 8 / 16 pt and font sizes 28 / 44 / 64 / 88 pt, measured on screen, so a Medium line looks the same on a 1000 px and a 4000 px image.
- **Rectangles** can be filled (fill colour defaults to white).
- **Select:** tap a shape to select it. Lines have 2 handles and rectangles 8; drag them to resize (a rectangle flips when dragged past its anchor). Drag any shape to move it. Tap text without moving to re-edit it. With a shape selected, colour, size and fill changes restyle it, and the context row shows layer order (to front, forward, backward, to back) and Delete.
- **Text:** tap to open an inline multi-line field with a format bar (font, bold, italic, underline, size, Done, Cancel). Tapping outside commits. Empty text is not added. The field is kept above the keyboard.
- **Zoom:** pinch with two fingers to zoom (up to 8x) and drag with two fingers to pan. In Select mode, one finger on empty space also pans while zoomed in. The floating controls at the bottom-right of the canvas zoom out, zoom in, and show the zoom level; tap the level to fit the image again. A second finger never draws: it drops any stroke or drag in progress.
- **History:** undo, redo and Clear all (confirmed, undoable). **Revert** (confirmed, not undoable) appears only when `originalPath` was given.
- **Close** asks "Discard changes?" when there are unsaved changes. The Android back button behaves the same (while the text field is open, back cancels the text edit first).

Annotations are only held in memory. Nothing but the flattened JPEG is ever saved.

## Behaviour notes

Where the spec left room, the plugin does this on both platforms:

- Shape geometry is stored in image pixels. Sizes chosen in screen points (dp on Android) are multiplied by the current image-pixels-per-point scale when a shape is created, so rotating the device never moves shapes.
- The 3 pt move threshold applies to every drag, not only text, so a tap that selects a shape never pushes an undo step.
- The text hit padding (8) is in screen points, like the other touch tolerances, so text is as easy to tap on a large image as on a small one.
- A tap with Pen, Line or Rect that draws nothing visible (fewer than 2 points, zero length or zero size) adds no shape and no undo step.
- Re-editing text without changing its size keeps its exact stored font size.
- The Impact font is not shipped with iOS or Android: iOS uses a heavy condensed system font, Android `sans-serif-condensed` bold. Georgia uses the platform serif on Android.
- Zoom does not change the size a new shape gets: stroke widths and font sizes are based on the fitted image, so an M line is the same part of the image at any zoom and the size buttons always match. Touch tolerances, handles and the selection outline stay the same size on screen at any zoom, so small shapes are easier to hit when zoomed in. The inline text field shows text at its real on-screen size for the current zoom.
- iOS presents the editor `.fullScreen`, which has no swipe-to-dismiss gesture. If it is dismissed by anything other than its own buttons, it sends `ImageAnnotationCancelled`.
- The output background is white, so transparent PNG areas become white in the JPEG.

## Testing

```bash
composer install
composer test
```

The Pest suite covers the facade, the bridge parameters, the event payloads, the manifest and cross-platform consistency checks on the native sources. The native editors need a device or simulator.

## License

MIT. See [LICENSE](LICENSE).
