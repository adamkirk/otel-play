<?php

namespace App\Services;

use App\Exceptions\CatalogueUnavailableException;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * HTTP client for the Go catalogue-api.
 */
class CatalogueClient
{
    /**
     * Fetch a product, or null when it does not exist.
     *
     * @return array{id: string, name: string, price_pence: int, stock: int}|null
     */
    public function getProduct(string $productId): ?array
    {
        $response = $this->send(fn (PendingRequest $http) => $http->get('/products/'.rawurlencode($productId)));

        if ($response->notFound()) {
            return null;
        }
        $this->ensureSuccessful($response, 'get product');

        return $response->json();
    }

    /**
     * Reserve stock for a product.
     *
     * @return bool false when there is not enough stock
     */
    public function reserve(string $productId, int $quantity): bool
    {
        $response = $this->send(fn (PendingRequest $http) => $http->post('/stock/reserve', [
            'product_id' => $productId,
            'quantity' => $quantity,
        ]));

        if ($response->status() === 409) {
            Log::warning('catalogue rejected reservation', [
                'product_id' => $productId,
                'quantity' => $quantity,
            ]);

            return false;
        }
        $this->ensureSuccessful($response, 'reserve stock');

        Log::info('stock reserved', [
            'product_id' => $productId,
            'quantity' => $quantity,
            'remaining' => $response->json('remaining'),
        ]);

        return true;
    }

    /**
     * @param  callable(PendingRequest): Response  $request
     */
    private function send(callable $request): Response
    {
        $http = Http::baseUrl(config('services.catalogue.url'))
            ->acceptJson()
            ->timeout(config('services.catalogue.timeout'));

        try {
            return $request($http);
        } catch (ConnectionException $e) {
            throw new CatalogueUnavailableException('catalogue-api unreachable: '.$e->getMessage(), previous: $e);
        }
    }

    private function ensureSuccessful(Response $response, string $action): void
    {
        if ($response->successful()) {
            return;
        }

        throw new CatalogueUnavailableException(
            "catalogue-api failed to {$action}: HTTP {$response->status()}",
        );
    }
}
