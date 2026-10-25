<?php

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Log;

/**
 * Cancels an order. The cancellation logic arrives in Stage 4 along with the
 * worker; for now this only proves the job is dispatched.
 */
class CancelOrder implements ShouldQueue
{
    use Queueable;

    public function __construct(public readonly int $orderId) {}

    public function handle(): void
    {
        Log::info('cancelling order', ['order_id' => $this->orderId]);
    }
}
