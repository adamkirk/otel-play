<?php

namespace App\Jobs;

use App\Enums\OrderStatus;
use App\Exceptions\PaymentDeclinedException;
use App\Models\Order;
use App\Services\PaymentGateway;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Context;
use Illuminate\Support\Facades\Log;
use Throwable;

/**
 * Takes payment for a pending order, then queues the confirmation.
 */
class ProcessOrder implements ShouldQueue
{
    use Queueable;

    public int $tries = 3;

    /** @var list<int> seconds to wait before each retry */
    public array $backoff = [2, 5];

    public function __construct(public readonly int $orderId) {}

    public function handle(PaymentGateway $payments): void
    {
        Context::add('order_id', $this->orderId);

        $order = Order::findOrFail($this->orderId);

        // It may have been cancelled while it sat on the queue.
        if ($order->status !== OrderStatus::Pending) {
            Log::info('order no longer pending, skipping payment', ['status' => $order->status->value]);

            return;
        }

        try {
            $payments->charge($order);
        } catch (PaymentDeclinedException $e) {
            $this->fail($e);

            return;
        }

        $order->update(['status' => OrderStatus::Paid, 'paid_at' => now()]);
        Log::info('payment taken', ['total_pence' => $order->total_pence]);

        SendConfirmation::dispatch($order->id);
    }

    /**
     * Runs once the job has given up, after a decline or the last retry.
     */
    public function failed(Throwable $e): void
    {
        Order::whereKey($this->orderId)
            ->where('status', OrderStatus::Pending)
            ->update(['status' => OrderStatus::Failed, 'failure_reason' => $e->getMessage()]);
    }
}
