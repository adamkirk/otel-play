<?php

namespace App\Enums;

enum OrderStatus: string
{
    /** Stock reserved, waiting for the worker to take payment. */
    case Pending = 'pending';

    case Paid = 'paid';

    /** Payment failed after all retries. */
    case Failed = 'failed';

    /** Never accepted: the catalogue could not reserve the stock. */
    case Rejected = 'rejected';

    case Cancelled = 'cancelled';

    public function isFinal(): bool
    {
        return $this !== self::Pending;
    }
}
