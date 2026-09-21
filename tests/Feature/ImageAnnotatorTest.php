<?php

use Pteal79\ImageAnnotator\Bridge\BridgeContract;
use Pteal79\ImageAnnotator\Bridge\NativeBridge;
use Pteal79\ImageAnnotator\Facades\ImageAnnotator;

it('registers the native bridge and a singleton', function () {
    expect(app(BridgeContract::class))->toBeInstanceOf(NativeBridge::class)
        ->and(app(Pteal79\ImageAnnotator\ImageAnnotator::class))
        ->toBe(app(Pteal79\ImageAnnotator\ImageAnnotator::class));
});

it('calls ImageAnnotator.Open with the paths and id', function () {
    $bridge = $this->fakeBridge()->respondTo('ImageAnnotator.Open', ['opened' => true]);

    $opened = ImageAnnotator::open(
        imagePath: '/cache/image-42.jpg',
        originalPath: '/cache/original-42.jpg',
        id: '42',
    );

    expect($opened)->toBeTrue()
        ->and($bridge->methods())->toBe(['ImageAnnotator.Open'])
        ->and($bridge->lastCall()['params'])->toBe([
            'imagePath' => '/cache/image-42.jpg',
            'id' => '42',
            'originalPath' => '/cache/original-42.jpg',
        ])
        ->and($bridge->lastCall()['json'])->toBe('{"imagePath":"/cache/image-42.jpg","id":"42","originalPath":"/cache/original-42.jpg"}');
});

it('leaves out originalPath when there is no original', function () {
    $bridge = $this->fakeBridge()->respondTo('ImageAnnotator.Open', ['opened' => true]);

    ImageAnnotator::open(imagePath: '/cache/image.jpg', id: '7');
    ImageAnnotator::open(imagePath: '/cache/image.jpg', id: '8', originalPath: '  ');

    expect($bridge->calls[0]['params'])->toBe(['imagePath' => '/cache/image.jpg', 'id' => '7'])
        ->and($bridge->calls[1]['params'])->toBe(['imagePath' => '/cache/image.jpg', 'id' => '8']);
});

it('returns false when native refuses or is missing', function (?array $response) {
    $this->fakeBridge()->respondTo('ImageAnnotator.Open', $response);

    expect(ImageAnnotator::open('/cache/image.jpg', '1'))->toBeFalse();
})->with([
    'already open' => [['opened' => false]],
    'error response' => [['status' => 'error', 'message' => 'nope']],
    'no bridge' => [null],
]);

it('returns false off-device without throwing', function () {
    expect(ImageAnnotator::open('/cache/image.jpg', '1'))->toBeFalse();
});

it('rejects a blank image path or id', function (string $path, string $id) {
    $bridge = $this->fakeBridge();

    expect(fn () => ImageAnnotator::open($path, $id))->toThrow(InvalidArgumentException::class)
        ->and($bridge->calls)->toBe([]);
})->with([
    'blank path' => [' ', '1'],
    'blank id' => ['/cache/image.jpg', ''],
]);
