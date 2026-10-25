<?php

namespace Tests\Feature;

use App\Enums\OrderStatus;
use App\Exceptions\PaymentDeclinedException;
use App\Exceptions\PaymentGatewayException;
use App\Jobs\CancelOrder;
use App\Jobs\ProcessOrder;
use App\Jobs\SendConfirmation;
use App\Models\Order;
use App\Services\PaymentGateway;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Queue;
use Mockery\MockInterface;
use Tests\TestCase;

class OrderJobsTest extends TestCase
{
    use RefreshDatabase;

    private function pendingOrder(): Order
    {
        return Order::create([
            'status' => OrderStatus::Pending,
            'customer_email' => 'demo@example.com',
            'total_pence' => 1200,
        ]);
    }

    public function test_successful_payment_marks_order_paid_and_queues_confirmation(): void
    {
        Queue::fake([SendConfirmation::class]);
        $this->mock(PaymentGateway::class, fn (MockInterface $m) => $m->expects('charge'));
        $order = $this->pendingOrder();

        ProcessOrder::dispatchSync($order->id);

        $order->refresh();
        $this->assertSame(OrderStatus::Paid, $order->status);
        $this->assertNotNull($order->paid_at);
        Queue::assertPushed(SendConfirmation::class, fn ($job) => $job->orderId === $order->id);
    }

    public function test_decline_fails_order_without_retrying(): void
    {
        Queue::fake([SendConfirmation::class]);
        $this->mock(PaymentGateway::class, fn (MockInterface $m) => $m->expects('charge')
            ->andThrow(new PaymentDeclinedException('Card declined.')));
        $order = $this->pendingOrder();

        ProcessOrder::dispatchSync($order->id);

        $order->refresh();
        $this->assertSame(OrderStatus::Failed, $order->status);
        $this->assertSame('Card declined.', $order->failure_reason);
        Queue::assertNothingPushed();
    }

    public function test_transient_error_is_thrown_so_the_worker_retries(): void
    {
        $this->mock(PaymentGateway::class, fn (MockInterface $m) => $m->expects('charge')
            ->andThrow(new PaymentGatewayException('Payment gateway timed out.')));
        $order = $this->pendingOrder();

        $this->expectException(PaymentGatewayException::class);

        (new ProcessOrder($order->id))->handle(app(PaymentGateway::class));
    }

    public function test_failed_hook_marks_pending_order_failed(): void
    {
        $order = $this->pendingOrder();

        (new ProcessOrder($order->id))->failed(new PaymentGatewayException('Payment gateway timed out.'));

        $this->assertSame(OrderStatus::Failed, $order->refresh()->status);
    }

    public function test_cancelled_order_is_not_charged(): void
    {
        $this->mock(PaymentGateway::class, fn (MockInterface $m) => $m->expects('charge')->never());
        $order = $this->pendingOrder();

        CancelOrder::dispatchSync($order->id);
        ProcessOrder::dispatchSync($order->id);

        $this->assertSame(OrderStatus::Cancelled, $order->refresh()->status);
    }

    public function test_cancel_leaves_final_orders_alone(): void
    {
        $order = Order::create(['status' => OrderStatus::Failed, 'total_pence' => 1200]);

        CancelOrder::dispatchSync($order->id);

        $this->assertSame(OrderStatus::Failed, $order->refresh()->status);
    }
}
