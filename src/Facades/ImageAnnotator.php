<?php

namespace Pteal79\ImageAnnotator\Facades;

use Illuminate\Support\Facades\Facade;

/**
 * @method static bool open(string $imagePath, string $id, ?string $originalPath = null)
 * @method static array params(string $imagePath, string $id, ?string $originalPath = null)
 *
 * @see \Pteal79\ImageAnnotator\ImageAnnotator
 */
class ImageAnnotator extends Facade
{
    protected static function getFacadeAccessor(): string
    {
        return \Pteal79\ImageAnnotator\ImageAnnotator::class;
    }
}
