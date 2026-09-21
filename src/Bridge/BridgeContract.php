<?php

namespace Pteal79\ImageAnnotator\Bridge;

interface BridgeContract
{
    /**
     * Whether a native bridge is present in this environment.
     */
    public function available(): bool;

    /**
     * Call a native bridge function.
     *
     * Returns the decoded response, or null when there is no bridge, the
     * function is not registered, or the call failed.
     *
     * @param  array<string, mixed>  $params
     * @return array<string, mixed>|null
     */
    public function call(string $method, array $params = []): ?array;
}
