<?php

namespace Pteal79\ImageAnnotator;

use InvalidArgumentException;
use Pteal79\ImageAnnotator\Bridge\BridgeContract;

/**
 * Opens the native annotation editor over a local image.
 *
 * The editor works on local files only. The result arrives later as exactly
 * one ImageAnnotationSaved, ImageAnnotationCancelled or ImageAnnotationFailed
 * event, each carrying the id passed here.
 */
class ImageAnnotator
{
    public const FUNCTION_OPEN = 'ImageAnnotator.Open';

    public function __construct(
        protected BridgeContract $bridge,
    ) {}

    /**
     * Present the editor. Returns straight away: true when native reported
     * that the editor is opening, false off-device or when it was refused
     * (a refusal still sends ImageAnnotationFailed).
     *
     * When $originalPath is given the editor shows Revert, which swaps the
     * image back to that file.
     *
     * @throws InvalidArgumentException when a path or the id is blank
     */
    public function open(string $imagePath, string $id, ?string $originalPath = null): bool
    {
        if (trim($imagePath) === '') {
            throw new InvalidArgumentException('The image path is required.');
        }

        if (trim($id) === '') {
            throw new InvalidArgumentException('The id is required.');
        }

        if ($originalPath !== null && trim($originalPath) === '') {
            $originalPath = null;
        }

        $response = $this->bridge->call(self::FUNCTION_OPEN, $this->params($imagePath, $id, $originalPath));

        return ($response['opened'] ?? false) === true;
    }

    /**
     * The parameters sent to ImageAnnotator.Open.
     *
     * @return array{imagePath: string, id: string, originalPath?: string}
     */
    public function params(string $imagePath, string $id, ?string $originalPath = null): array
    {
        $params = ['imagePath' => $imagePath, 'id' => $id];

        if ($originalPath !== null) {
            $params['originalPath'] = $originalPath;
        }

        return $params;
    }
}
