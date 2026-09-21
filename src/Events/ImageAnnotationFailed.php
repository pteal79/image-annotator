<?php

namespace Pteal79\ImageAnnotator\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;
use Native\Mobile\Events\Concerns\BroadcastsGlobally;

/**
 * The editor could not load the input or write the output, or another
 * editor was already open (message "already open").
 */
class ImageAnnotationFailed implements BroadcastsGlobally
{
    use Dispatchable, SerializesModels;

    public const ALREADY_OPEN = 'already open';

    public function __construct(
        public string $id = '',
        public string $message = '',
    ) {}

    public function alreadyOpen(): bool
    {
        return $this->message === self::ALREADY_OPEN;
    }
}
