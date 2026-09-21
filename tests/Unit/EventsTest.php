<?php

use Native\Mobile\Events\Concerns\BroadcastsGlobally;
use Pteal79\ImageAnnotator\Events\ImageAnnotationCancelled;
use Pteal79\ImageAnnotator\Events\ImageAnnotationFailed;
use Pteal79\ImageAnnotator\Events\ImageAnnotationSaved;

it('builds each event from its native payload', function () {
    $saved = new ImageAnnotationSaved(...[
        'id' => '42',
        'outputPath' => '/cache/annotated-42-1.jpg',
        'width' => 4032,
        'height' => 3024,
        'reverted' => true,
    ]);

    expect($saved->id)->toBe('42')
        ->and($saved->outputPath)->toBe('/cache/annotated-42-1.jpg')
        ->and($saved->width)->toBe(4032)
        ->and($saved->height)->toBe(3024)
        ->and($saved->reverted)->toBeTrue()
        ->and((new ImageAnnotationCancelled(id: '42'))->id)->toBe('42')
        ->and((new ImageAnnotationFailed(id: '42', message: 'already open'))->alreadyOpen())->toBeTrue()
        ->and((new ImageAnnotationFailed(id: '42', message: "Couldn't load the image."))->alreadyOpen())->toBeFalse();
});

it('marks every event for SuperNative delivery', function (string $event) {
    expect(new $event)->toBeInstanceOf(BroadcastsGlobally::class);
})->with([
    ImageAnnotationSaved::class,
    ImageAnnotationCancelled::class,
    ImageAnnotationFailed::class,
]);

it('has constructor parameters matching the payload keys native sends', function (string $event, array $keys) {
    $parameters = array_map(
        fn (ReflectionParameter $p) => $p->getName(),
        (new ReflectionMethod($event, '__construct'))->getParameters(),
    );

    expect($parameters)->toBe($keys);
})->with([
    [ImageAnnotationSaved::class, ['id', 'outputPath', 'width', 'height', 'reverted']],
    [ImageAnnotationCancelled::class, ['id']],
    [ImageAnnotationFailed::class, ['id', 'message']],
]);
