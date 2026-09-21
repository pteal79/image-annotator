<?php

namespace Pteal79\ImageAnnotator\Tests\Fakes;

use Pteal79\ImageAnnotator\Bridge\BridgeContract;

class FakeNativeBridge implements BridgeContract
{
    /** @var array<int, array{method: string, params: array<string, mixed>, json: string}> */
    public array $calls = [];

    /** @var array<string, array<string, mixed>|null> */
    public array $responses = [];

    public bool $available = true;

    public function available(): bool
    {
        return $this->available;
    }

    public function call(string $method, array $params = []): ?array
    {
        $this->calls[] = [
            'method' => $method,
            'params' => $params,
            'json' => json_encode((object) $params, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE),
        ];

        return $this->responses[$method] ?? null;
    }

    /**
     * @param  array<string, mixed>|null  $response
     */
    public function respondTo(string $method, ?array $response): static
    {
        $this->responses[$method] = $response;

        return $this;
    }

    /**
     * @return array{method: string, params: array<string, mixed>, json: string}|null
     */
    public function lastCall(): ?array
    {
        return $this->calls === [] ? null : $this->calls[array_key_last($this->calls)];
    }

    /**
     * @return array<int, string>
     */
    public function methods(): array
    {
        return array_column($this->calls, 'method');
    }
}
