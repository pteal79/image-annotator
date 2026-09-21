<?php

namespace Pteal79\ImageAnnotator\Tests;

use Native\Mobile\NativeServiceProvider;
use Orchestra\Testbench\TestCase as BaseTestCase;
use Pteal79\ImageAnnotator\Bridge\BridgeContract;
use Pteal79\ImageAnnotator\Facades\ImageAnnotator;
use Pteal79\ImageAnnotator\ImageAnnotatorServiceProvider;
use Pteal79\ImageAnnotator\Tests\Fakes\FakeNativeBridge;

abstract class TestCase extends BaseTestCase
{
    protected function getPackageProviders($app): array
    {
        return [
            NativeServiceProvider::class,
            ImageAnnotatorServiceProvider::class,
        ];
    }

    protected function getPackageAliases($app): array
    {
        return [
            'ImageAnnotator' => ImageAnnotator::class,
        ];
    }

    protected function defineEnvironment($app): void
    {
        $app['config']->set('nativephp.app_id', 'com.test.app');
    }

    /**
     * Swap the plugin's bridge for an in-memory fake.
     */
    protected function fakeBridge(): FakeNativeBridge
    {
        $fake = new FakeNativeBridge;

        $this->app->instance(BridgeContract::class, $fake);
        $this->app->forgetInstance(\Pteal79\ImageAnnotator\ImageAnnotator::class);
        ImageAnnotator::clearResolvedInstances();

        return $fake;
    }
}
