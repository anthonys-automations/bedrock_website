<?php

/**
 * Configuration overrides for WP_ENV === 'production'
 */

use Roots\WPConfig\Config;

use function Env\env;

/**
 * You should try to keep staging as close to production as possible. However,
 * should you need to, you can always override production configuration values
 * with `Config::define`.
 *
 * Example: `Config::define('WP_DEBUG', true);`
 * Example: `Config::define('DISALLOW_FILE_MODS', false);`
 */

Config::define('DISALLOW_INDEXING', false);
Config::define('WP_MEMORY_LIMIT', '128M');

Config::define('WP_DEBUG', true);
Config::define('WP_DEBUG_DISPLAY', false);
// Left false so WordPress does not override PHP's error_log: errors then go to
// Apache's error log and out to the container's stderr. The previous
// '/var/log/php/wp.log' target disappeared with PHP-FPM and would have hidden
// application errors in a file inside the container.
Config::define('WP_DEBUG_LOG', false);

if (env('PROXY_HOST')) {
    Config::define('WP_PROXY_HOST', env('PROXY_HOST'));
    Config::define('WP_PROXY_PORT', env('PROXY_PORT') ?: '8888');
}

// Config::define('WP_HTTP_BLOCK_EXTERNAL', TRUE);
// Config::define('WP_ACCESSIBLE_HOSTS', 'wordpress.org, domain.com');

Config::define('WP_CACHE', true); // WP-Optimize Cache
