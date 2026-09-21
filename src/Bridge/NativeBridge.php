<?php

namespace Pteal79\ImageAnnotator\Bridge;

use Illuminate\Support\Facades\Log;
use Throwable;

/**
 * Thin wrapper around NativePHP's nativephp_call() so it can be swapped for a
 * fake in tests. Never throws: a missing or failing bridge returns null.
 */
class NativeBridge implements BridgeContract
{
    public function __construct(
        protected string $function = 'nativephp_call',
    ) {}

    public function available(): bool
    {
        return function_exists($this->function);
    }

    public function call(string $method, array $params = []): ?array
    {
        if (! $this->available()) {
            return null;
        }

        try {
            // Encode as an object so an empty parameter list is sent as "{}".
            $json = json_encode((object) $params, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
            $result = ($this->function)($method, $json);
        } catch (Throwable $e) {
            Log::warning("[pteal79/image-annotator] Native call {$method} failed: {$e->getMessage()}");

            return null;
        }

        if (! is_string($result) || $result === '') {
            return null;
        }

        $decoded = json_decode($result, true);

        return is_array($decoded) ? $decoded : null;
    }
}
