<?php

namespace Pteal79\ImageAnnotator;

use Illuminate\Support\ServiceProvider;
use Pteal79\ImageAnnotator\Bridge\BridgeContract;
use Pteal79\ImageAnnotator\Bridge\NativeBridge;

class ImageAnnotatorServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singletonIf(BridgeContract::class, NativeBridge::class);

        $this->app->singleton(ImageAnnotator::class, fn ($app) => new ImageAnnotator(
            $app->make(BridgeContract::class),
        ));
    }
}
