<?php

namespace App\Jobs;

use App\Enums\OrderStatus;
use App\Models\Order;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Context;
use Illuminate\Support\Facades\Log;

/**
 * Cancels a pending or paid order. A real shop would also refund payment and
 * release stock; this one just changes the status.
 */
class CancelOrder implements ShouldQueue
{
    use Queueable;

    public function __construct(public readonly int $orderId) {}

    public function handle(): void
    {
        Context::add('order_id', $this->orderId);

        $order = Order::findOrFail($this->orderId);

        if (! in_array($order->status, [OrderStatus::Pending, OrderStatus::Paid], true)) {
            Log::info('order cannot be cancelled, skipping', ['status' => $order->status->value]);

            return;
        }

        $previous = $order->status;
        $order->update(['status' => OrderStatus::Cancelled]);
        Log::info('order cancelled', ['previous_status' => $previous->value]);
    }
}
