<?php

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\Log;

/**
 * Takes payment for a pending order. The payment logic arrives in Stage 4
 * along with the worker; for now this only proves the job is dispatched.
 */
class ProcessOrder implements ShouldQueue
{
    use Queueable;

    public function __construct(public readonly int $orderId) {}

    public function handle(): void
    {
        Log::info('processing order', ['order_id' => $this->orderId]);
    }
}
