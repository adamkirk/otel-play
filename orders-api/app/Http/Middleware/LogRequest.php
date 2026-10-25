<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpFoundation\Response;

/**
 * Logs one line per request, matching catalogue-api's request log. Health
 * checks are skipped to keep the logs readable.
 */
class LogRequest
{
    public function handle(Request $request, Closure $next): Response
    {
        return $next($request);
    }

    public function terminate(Request $request, Response $response): void
    {
        if ($request->is('up')) {
            return;
        }

        $status = $response->getStatusCode();
        $startedAt = defined('LARAVEL_START') ? LARAVEL_START : $request->server('REQUEST_TIME_FLOAT');

        Log::log($status >= 500 ? 'error' : 'info', 'request', [
            'method' => $request->method(),
            'path' => '/'.ltrim($request->path(), '/'),
            'status' => $status,
            'duration_ms' => (int) round((microtime(true) - $startedAt) * 1000),
        ]);
    }
}
