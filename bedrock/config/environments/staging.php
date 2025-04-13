<?php

/**
 * Configuration overrides for WP_ENV === 'staging'
 */

use Roots\WPConfig\Config;

/**
 * You should try to keep staging as close to production as possible. However,
 * should you need to, you can always override production configuration values
 * with `Config::define`.
 *
 * Example: `Config::define('WP_DEBUG', true);`
 * Example: `Config::define('DISALLOW_FILE_MODS', false);`
 */

Config::define('DISALLOW_INDEXING', true);
Config::define('WP_MEMORY_LIMIT', '128M');

Config::define('WP_DEBUG', true);
Config::define('WP_DEBUG_DISPLAY', true);
Config::define('WP_DEBUG_LOG', '/var/log/php/wp.log');

Config::define('WP_PROXY_HOST', '10.0.1.17');
Config::define('WP_PROXY_PORT', '8888');
// Config::define('WP_HTTP_BLOCK_EXTERNAL', TRUE);
// Config::define('WP_ACCESSIBLE_HOSTS', 'wordpress.org, domain.com');
