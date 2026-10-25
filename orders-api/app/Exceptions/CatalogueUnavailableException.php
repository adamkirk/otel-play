<?php

namespace App\Exceptions;

use Illuminate\Http\JsonResponse;
use RuntimeException;

class CatalogueUnavailableException extends RuntimeException
{
    public function render(): JsonResponse
    {
        return response()->json(['message' => 'Catalogue service unavailable.'], 502);
    }
}
