<?php

namespace App\Exceptions;

use RuntimeException;

/** A transient payment failure. The job retries it. */
class PaymentGatewayException extends RuntimeException {}
