<?php

use Pteal79\ImageAnnotator\Tests\TestCase;

uses(TestCase::class)->in('Unit', 'Feature');

function packagePath(string $path = ''): string
{
    return dirname(__DIR__).($path === '' ? '' : '/'.ltrim($path, '/'));
}

function manifest(): array
{
    return json_decode(file_get_contents(packagePath('nativephp.json')), true, flags: JSON_THROW_ON_ERROR);
}
