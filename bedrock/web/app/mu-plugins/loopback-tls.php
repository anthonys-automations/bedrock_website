<?php

/**
 * Use the container's generated certificate for requests back to WP_HOME.
 */
add_filter('http_request_args', static function (array $args, string $url): array {
    $siteHost = getenv('SITE_NAME');

    if ($siteHost !== false && wp_parse_url($url, PHP_URL_HOST) === $siteHost) {
        $args['sslcertificates'] = '/etc/ssl/bedrock/server.crt';
    }

    return $args;
}, 10, 2);