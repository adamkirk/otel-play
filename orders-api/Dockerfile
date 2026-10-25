# One image for both the API (php-fpm, the default CMD) and the queue worker
# (`php artisan queue:work`, set by the Helm chart). nginx runs as a sidecar.
FROM php:8.4-fpm AS base

COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions pdo_mysql redis opcache pcntl

COPY docker/php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php-fpm.conf /usr/local/etc/php-fpm.d/zz-app.conf

WORKDIR /var/www/html

FROM base AS vendor
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --no-interaction --prefer-dist

COPY . .
RUN composer dump-autoload --optimize --no-dev \
    && php artisan package:discover --ansi

FROM base AS app
COPY --from=vendor --chown=www-data:www-data /var/www/html /var/www/html
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint

USER www-data
EXPOSE 9000
ENTRYPOINT ["entrypoint"]
CMD ["php-fpm"]
