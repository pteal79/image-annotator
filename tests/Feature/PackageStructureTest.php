<?php

use Native\Mobile\Plugins\PluginManifest;

const KOTLIN_PACKAGE = 'com.pteal79.plugins.imageannotator';

const EVENTS = [
    'Pteal79\\ImageAnnotator\\Events\\ImageAnnotationSaved',
    'Pteal79\\ImageAnnotator\\Events\\ImageAnnotationCancelled',
    'Pteal79\\ImageAnnotator\\Events\\ImageAnnotationFailed',
];

function kotlinSources(): array
{
    return glob(packagePath('resources/android/src/*.kt'));
}

function swiftSources(): array
{
    return glob(packagePath('resources/ios/Sources/*.swift'));
}

describe('nativephp.json', function () {
    it('is accepted by the NativePHP manifest parser', function () {
        $parsed = PluginManifest::fromFile(packagePath('nativephp.json'));

        expect($parsed->namespace)->toBe('ImageAnnotator')
            ->and($parsed->bridgeFunctions)->toHaveCount(1)
            ->and(manifest()['platforms'])->toBe(['android', 'ios']);
    });

    it('maps ImageAnnotator.Open to both platforms', function () {
        expect(manifest()['bridge_functions'])->toBe([[
            'name' => 'ImageAnnotator.Open',
            'android' => KOTLIN_PACKAGE.'.ImageAnnotatorFunctions.Open',
            'ios' => 'ImageAnnotatorFunctions.Open',
            'description' => manifest()['bridge_functions'][0]['description'],
        ]]);
    });

    it('lists event classes that exist', function () {
        expect(manifest()['events'])->toBe(EVENTS);

        foreach (EVENTS as $event) {
            expect(class_exists($event))->toBeTrue("{$event} does not exist");
        }
    });

    it('needs no permissions and registers the editor activity', function () {
        $android = manifest()['android'];

        expect($android['permissions'])->toBe([])
            ->and($android['min_version'])->toBe(26)
            ->and($android['activities'])->toHaveCount(1)
            ->and($android['activities'][0]['name'])->toBe('.AnnotatorActivity')
            ->and($android['activities'][0]['exported'])->toBeFalse()
            ->and($android['activities'][0]['configChanges'])->toContain('orientation|screenSize')
            ->and(manifest()['ios']['info_plist'])->toBe([])
            ->and(manifest()['ios']['min_version'])->toBe('18.2');
    });
});

describe('native sources', function () {
    it('declares the plugin package at the top of every Kotlin file', function () {
        expect(kotlinSources())->not->toBeEmpty();

        foreach (kotlinSources() as $file) {
            expect(file_get_contents($file))->toStartWith('package '.KOTLIN_PACKAGE."\n");
        }
    });

    it('implements the bridge functions on both platforms', function () {
        $kotlin = file_get_contents(packagePath('resources/android/src/ImageAnnotatorFunctions.kt'));
        $swift = file_get_contents(packagePath('resources/ios/Sources/ImageAnnotatorFunctions.swift'));

        expect($kotlin)->toContain('object ImageAnnotatorFunctions {')
            ->toMatch('/class Open\(private val activity: FragmentActivity\) : BridgeFunction/')
            ->and($swift)->toContain('enum ImageAnnotatorFunctions {')
            ->toContain('class Open: BridgeFunction');
    });

    it('declares the Android activity class named in the manifest', function () {
        expect(file_get_contents(packagePath('resources/android/src/AnnotatorActivity.kt')))
            ->toContain('class AnnotatorActivity : AppCompatActivity()');
    });

    it('presents AnnotatorViewController full screen on iOS', function () {
        expect(file_get_contents(packagePath('resources/ios/Sources/ImageAnnotatorFunctions.swift')))
            ->toContain('AnnotatorViewController(request: request)')
            ->toContain('.fullScreen');
    });

    it('dispatches the event classes listed in the manifest', function () {
        $kotlin = file_get_contents(packagePath('resources/android/src/AnnotatorSession.kt'));
        $swift = file_get_contents(packagePath('resources/ios/Sources/ImageAnnotatorFunctions.swift'));

        foreach (EVENTS as $event) {
            $escaped = str_replace('\\', '\\\\', $event);

            expect($kotlin)->toContain("\"{$escaped}\"")
                ->and($swift)->toContain("\"{$escaped}\"");
        }
    });

    it('sends payload keys that match the event constructor parameters', function () {
        $sources = file_get_contents(packagePath('resources/android/src/AnnotatorSession.kt'))
            .file_get_contents(packagePath('resources/ios/Sources/ImageAnnotatorFunctions.swift'));

        foreach (['id', 'outputPath', 'width', 'height', 'reverted', 'message'] as $key) {
            expect($sources)->toContain("\"{$key}\"");
        }

        expect($sources)->toContain('"already open"');
    });

    it('uses the same size presets, palette and metrics on both platforms', function () {
        $kotlin = file_get_contents(packagePath('resources/android/src/AnnotatorModel.kt'));
        $swift = file_get_contents(packagePath('resources/ios/Sources/AnnotatorModel.swift'));

        foreach (['"#ef4444"', '"#f97316"', '"#eab308"', '"#22c55e"', '"#3b82f6"', '"#000000"', '"#ffffff"', '"#38bdf8"'] as $color) {
            expect($kotlin)->toContain($color)->and($swift)->toContain($color);
        }

        foreach ([['2f, 28f', 'return 2', 'return 28'], ['4f, 44f', 'return 4', 'return 44'], ['8f, 64f', 'return 8', 'return 64'], ['16f, 88f', 'return 16', 'return 88']] as [$k, $stroke, $font]) {
            expect($kotlin)->toContain($k)->and($swift)->toContain($stroke)->and($swift)->toContain($font);
        }
    });

    it('exports JPEG at quality 0.92 named annotated-{id}-{timestamp}.jpg', function () {
        $kotlin = file_get_contents(packagePath('resources/android/src/AnnotatorActivity.kt'));
        $swift = file_get_contents(packagePath('resources/ios/Sources/AnnotatorRenderer.swift'))
            .file_get_contents(packagePath('resources/ios/Sources/AnnotatorViewController.swift'));

        expect($kotlin)->toContain('JPEG_QUALITY = 92')
            ->toContain('"annotated-${safeFileId(request.id)}-${System.currentTimeMillis()}.jpg"')
            ->and($swift)->toContain('jpegData(compressionQuality: 0.92)')
            ->toContain('"annotated-\\(Self.safeFileId(request.id))-');
    });

    it('keeps native sources free of placeholders and hardcoded Package.swift files', function () {
        foreach ([...kotlinSources(), ...swiftSources()] as $file) {
            expect(file_get_contents($file))->not->toContain('TODO')->not->toContain('FIXME');
        }

        expect(file_exists(packagePath('resources/ios/Package.swift')))->toBeFalse();
    });
});

describe('package', function () {
    it('has the expected composer metadata', function () {
        $composer = json_decode(file_get_contents(packagePath('composer.json')), true);

        expect($composer['name'])->toBe('pteal79/image-annotator')
            ->and($composer['type'])->toBe('nativephp-plugin')
            ->and($composer['autoload']['psr-4'])->toBe(['Pteal79\\ImageAnnotator\\' => 'src/'])
            ->and($composer['extra']['laravel']['providers'])->toBe(['Pteal79\\ImageAnnotator\\ImageAnnotatorServiceProvider'])
            ->and($composer['extra']['laravel']['aliases'])->toBe(['ImageAnnotator' => 'Pteal79\\ImageAnnotator\\Facades\\ImageAnnotator'])
            ->and($composer['extra']['nativephp']['manifest'])->toBe('nativephp.json');
    });

    it('does not ship a JavaScript library', function () {
        expect(is_dir(packagePath('resources/js')))->toBeFalse();
    });

    it('has no em-dashes in user-facing files', function () {
        $files = [
            packagePath('README.md'),
            packagePath('CHANGELOG.md'),
            packagePath('nativephp.json'),
            packagePath('resources/boost/guidelines/core.blade.php'),
            ...glob(packagePath('src/*.php')),
            ...glob(packagePath('src/*/*.php')),
            ...kotlinSources(),
            ...swiftSources(),
        ];

        foreach ($files as $file) {
            expect(file_get_contents($file))->not->toContain("\u{2014}", basename($file).' contains an em-dash');
        }
    });
});
