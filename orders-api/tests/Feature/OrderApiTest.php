<?php

namespace Tests\Feature;

use App\Enums\OrderStatus;
use App\Jobs\CancelOrder;
use App\Jobs\ProcessOrder;
use App\Models\Order;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Queue;
use Tests\TestCase;

class OrderApiTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        config(['services.catalogue.url' => 'http://catalogue.test']);
        Queue::fake();
    }

    private function fakeCatalogue(int $reserveStatus = 200): void
    {
        Http::fake([
            'catalogue.test/products/mug-enamel' => Http::response([
                'id' => 'mug-enamel', 'name' => 'Enamel Mug', 'price_pence' => 1200, 'stock' => 30,
            ]),
            'catalogue.test/products/*' => Http::response(['error' => 'product not found'], 404),
            'catalogue.test/stock/reserve' => Http::response(['remaining' => 28], $reserveStatus),
        ]);
    }

    public function test_creates_order_reserves_stock_and_queues_processing(): void
    {
        $this->fakeCatalogue();

        $response = $this->postJson('/api/orders', [
            'items' => [['product_id' => 'mug-enamel', 'quantity' => 2]],
        ]);

        $response->assertCreated()
            ->assertJsonPath('data.status', 'pending')
            ->assertJsonPath('data.total_pence', 2400)
            ->assertJsonPath('data.items.0.product_name', 'Enamel Mug');

        Http::assertSent(fn ($request) => $request->url() === 'http://catalogue.test/stock/reserve'
            && $request['quantity'] === 2);
        Queue::assertPushed(ProcessOrder::class, fn ($job) => $job->orderId === $response->json('data.id'));
    }

    public function test_rejects_order_when_stock_is_insufficient(): void
    {
        $this->fakeCatalogue(reserveStatus: 409);

        $this->postJson('/api/orders', [
            'items' => [['product_id' => 'mug-enamel', 'quantity' => 2]],
        ])->assertConflict()->assertJsonPath('data.status', 'rejected');

        Queue::assertNothingPushed();
    }

    public function test_unknown_product_is_a_validation_error(): void
    {
        $this->fakeCatalogue();

        $this->postJson('/api/orders', [
            'items' => [['product_id' => 'nope', 'quantity' => 1]],
        ])->assertUnprocessable()->assertJsonValidationErrors('items.0.product_id');

        $this->assertDatabaseCount('orders', 0);
    }

    public function test_catalogue_outage_returns_bad_gateway(): void
    {
        Http::fake(['catalogue.test/*' => Http::response(null, 503)]);

        $this->postJson('/api/orders', [
            'items' => [['product_id' => 'mug-enamel', 'quantity' => 1]],
        ])->assertStatus(502);
    }

    public function test_shows_and_lists_orders(): void
    {
        $order = Order::create(['status' => OrderStatus::Paid, 'total_pence' => 650]);

        $this->getJson("/api/orders/{$order->id}")->assertOk()->assertJsonPath('data.status', 'paid');
        $this->getJson('/api/orders')->assertOk()->assertJsonCount(1, 'data');
    }

    public function test_cancel_queues_job_unless_already_final(): void
    {
        $pending = Order::create(['status' => OrderStatus::Pending, 'total_pence' => 650]);
        $rejected = Order::create(['status' => OrderStatus::Rejected, 'total_pence' => 650]);

        $this->postJson("/api/orders/{$pending->id}/cancel")->assertAccepted();
        $this->postJson("/api/orders/{$rejected->id}/cancel")->assertConflict();

        Queue::assertPushed(CancelOrder::class, 1);
    }

    public function test_cors_allows_the_shop_origin(): void
    {
        $this->withHeaders([
            'Origin' => 'http://shop.localhost',
            'Access-Control-Request-Method' => 'POST',
        ])->options('/api/orders')
            ->assertHeader('Access-Control-Allow-Origin', 'http://shop.localhost');
    }
}
