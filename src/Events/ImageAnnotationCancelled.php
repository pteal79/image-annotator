<?php

namespace Pteal79\ImageAnnotator\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;
use Native\Mobile\Events\Concerns\BroadcastsGlobally;

/**
 * The user closed the editor without saving.
 */
class ImageAnnotationCancelled implements BroadcastsGlobally
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $id = '',
    ) {}
}
