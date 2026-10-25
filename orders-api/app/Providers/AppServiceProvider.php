<?php

namespace App\Providers;

use Illuminate\Contracts\Queue\Job;
use Illuminate\Queue\Events\JobExceptionOccurred;
use Illuminate\Queue\Events\JobFailed;
use Illuminate\Queue\Events\JobProcessed;
use Illuminate\Queue\Events\JobProcessing;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    /** @var array<string, float> job uuid => start time */
    private array $jobStartedAt = [];

    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        $this->logQueueJobs();
    }

    /**
     * Log one line when each job starts and one when it finishes, fails an
     * attempt, or gives up. This is the worker's equivalent of the
     * LogRequest middleware.
     */
    private function logQueueJobs(): void
    {
        Queue::before(function (JobProcessing $event) {
            $this->jobStartedAt[$event->job->uuid()] = microtime(true);
            Log::info('job started', $this->jobFields($event->job));
        });

        Queue::after(function (JobProcessed $event) {
            Log::info('job processed', $this->jobFields($event->job, withDuration: true));
        });

        Event::listen(function (JobExceptionOccurred $event) {
            Log::warning('job attempt failed', [
                ...$this->jobFields($event->job, withDuration: true),
                'error' => $event->exception->getMessage(),
                'will_retry' => ! $event->job->hasFailed(),
            ]);
        });

        Queue::failing(function (JobFailed $event) {
            Log::error('job failed', [
                ...$this->jobFields($event->job),
                'error' => $event->exception->getMessage(),
            ]);
        });
    }

    private function jobFields(Job $job, bool $withDuration = false): array
    {
        $fields = [
            'job' => class_basename($job->resolveName()),
            'job_id' => $job->uuid(),
            'queue' => $job->getQueue(),
            'attempt' => $job->attempts(),
        ];

        $startedAt = $this->jobStartedAt[$job->uuid()] ?? null;
        if ($withDuration && $startedAt !== null) {
            $fields['duration_ms'] = (int) round((microtime(true) - $startedAt) * 1000);
            unset($this->jobStartedAt[$job->uuid()]);
        }

        return $fields;
    }
}
