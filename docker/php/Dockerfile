FROM php:8.5-fpm-bookworm

RUN docker-php-ext-install pdo_mysql

WORKDIR /var/www/html

CMD ["php-fpm"]
