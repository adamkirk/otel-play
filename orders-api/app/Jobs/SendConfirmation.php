<?php

namespace App\Jobs;

use App\Models\Order;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Context;
use Illuminate\Support\Facades\Log;

/**
 * Stands in for sending an order confirmation email.
 */
class SendConfirmation implements ShouldQueue
{
    use Queueable;

    public function __construct(public readonly int $orderId) {}

    public function handle(): void
    {
        Context::add('order_id', $this->orderId);

        $order = Order::findOrFail($this->orderId);

        if ($order->customer_email === null) {
            Log::info('no customer email, skipping confirmation');

            return;
        }

        usleep(random_int(50, 300) * 1000);
        Log::info('confirmation email sent', ['to' => $order->customer_email]);
    }
}
