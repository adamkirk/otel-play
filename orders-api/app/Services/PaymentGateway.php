<?php

namespace App\Services;

use App\Exceptions\PaymentDeclinedException;
use App\Exceptions\PaymentGatewayException;
use App\Models\Order;

/**
 * A pretend card processor: slow, occasionally flaky, sometimes declines.
 */
class PaymentGateway
{
    /**
     * @throws PaymentGatewayException when the gateway has a transient error (worth retrying)
     * @throws PaymentDeclinedException when the payment is declined (not worth retrying)
     */
    public function charge(Order $order): void
    {
        $config = config('orders.payment');

        usleep(random_int($config['min_latency_ms'], $config['max_latency_ms']) * 1000);

        $roll = random_int(0, PHP_INT_MAX - 1) / PHP_INT_MAX;

        if ($roll < $config['transient_failure_rate']) {
            throw new PaymentGatewayException('Payment gateway timed out.');
        }

        if ($roll < $config['transient_failure_rate'] + $config['decline_rate']) {
            throw new PaymentDeclinedException('Card declined.');
        }
    }
}
