<?php

namespace Pteal79\ImageAnnotator\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;
use Native\Mobile\Events\Concerns\BroadcastsGlobally;

/**
 * The user pressed Save. outputPath is a JPEG (quality 0.92) in the app's
 * cache dir, at the full pixel size of the loaded image. The app owns the
 * file from now on and should delete it when done. reverted is true when
 * Revert was used in this session.
 */
class ImageAnnotationSaved implements BroadcastsGlobally
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $id = '',
        public string $outputPath = '',
        public int $width = 0,
        public int $height = 0,
        public bool $reverted = false,
    ) {}
}
