## pteal79/image-annotator

A full-screen native image annotation editor for NativePHP Mobile v4 (iOS and Android). The user draws freehand lines, lines, rectangles and text on a local image, then saves a flattened JPEG. Local files only, no network. There is no JavaScript API.

### PHP Usage (SuperNative)

@verbatim
<code-snippet name="Opening the annotator" lang="php">
use Pteal79\ImageAnnotator\Facades\ImageAnnotator;

// Returns straight away. Use named arguments.
ImageAnnotator::open(
    imagePath: $localPath,            // required local JPEG/PNG
    originalPath: $localOriginalPath, // optional, shows Revert
    id: (string) $jobImageId,         // required, echoed in every event
);
</code-snippet>
@endverbatim

- `ImageAnnotator::open(string $imagePath, string $id, ?string $originalPath = null): bool`: true when the editor is opening, false off-device or when refused. Throws `InvalidArgumentException` for a blank path or id.
- Inputs should be downscaled to a long edge of at most 4096 px. EXIF orientation is applied.

### Events

Each `open()` ends with exactly one event, sent after the editor is dismissed:

- `ImageAnnotationSaved(string $id, string $outputPath, int $width, int $height, bool $reverted)`: a JPEG (quality 0.92) in the cache dir named `annotated-{id}-{timestamp}.jpg`. The app owns it and must move or delete it.
- `ImageAnnotationCancelled(string $id)`: closed without saving.
- `ImageAnnotationFailed(string $id, string $message)`: the input could not be loaded, or `message` is `"already open"`.

@verbatim
<code-snippet name="Handling the result in a NativeComponent" lang="php">
use Native\Mobile\Attributes\On;
use Pteal79\ImageAnnotator\Events\ImageAnnotationSaved;

#[On(ImageAnnotationSaved::class)]
public function saved(string $id = '', string $outputPath = '', int $width = 0, int $height = 0, bool $reverted = false): void
{
    // Move $outputPath somewhere permanent, then queue the upload.
}
</code-snippet>
@endverbatim

- Match on `$id`: several screens may listen for the same events.
- Annotations are not saved as editable data. Only the flattened JPEG comes back.
