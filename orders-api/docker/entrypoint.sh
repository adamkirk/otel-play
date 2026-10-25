#!/bin/sh
set -e

# Cache config, routes and events from the pod's environment. This happens at
# start-up rather than build time because config:cache bakes in env values.
php artisan optimize --no-ansi -q

exec "$@"
