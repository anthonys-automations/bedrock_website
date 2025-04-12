<?php
/**
 * Plugin Name: Force REST API to use localhost
 * Description: Forces REST API URLs to use localhost:80
 * Version: 1.0
 * Author: Your Name
 */

// Check if the constant is defined
if (defined('FORCE_REST_API_LOCALHOST') && FORCE_REST_API_LOCALHOST) {
    // Add filter for REST URL
    add_filter('rest_url', function($url, $path) {
        // Parse the original URL to keep the path structure
        $parsed = parse_url($url);
        // Build new URL with localhost but keep the path structure
        return 'http://localhost:80' . $parsed['path'];
    }, 99, 2);
}
