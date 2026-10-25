<?php

namespace App\Exceptions;

use RuntimeException;

/** A permanent payment failure. Retrying won't help. */
class PaymentDeclinedException extends RuntimeException {}
