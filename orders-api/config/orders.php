<?php

return [

    /*
    | The fake payment gateway used by the ProcessOrder job. Rates are
    | probabilities per attempt: transient failures are retried, declines
    | fail the order immediately.
    */
    'payment' => [
        'min_latency_ms' => (int) env('PAYMENT_MIN_LATENCY_MS', 200),
        'max_latency_ms' => (int) env('PAYMENT_MAX_LATENCY_MS', 1500),
        'transient_failure_rate' => (float) env('PAYMENT_TRANSIENT_FAILURE_RATE', 0.1),
        'decline_rate' => (float) env('PAYMENT_DECLINE_RATE', 0.05),
    ],

];
