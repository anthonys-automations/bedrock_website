<?php
/**
 * Disable Canada Post Shipping Method if no products have the "Canada Post" shipping class.
 */

// Hook into WordPress init to ensure all plugins are loaded
add_action('plugins_loaded', 'initialize_custom_shipping_methods_filter');

function initialize_custom_shipping_methods_filter() {
    // Add our filter after WooCommerce is fully loaded
    add_filter('woocommerce_package_rates', 'custom_shipping_methods_filter', 10, 2);
}

function custom_shipping_methods_filter($rates, $package) {
    // Check if the cart is empty
    if (empty(WC()->cart)) {
        return $rates; // Early return if the cart is empty
    }

    $is_canada_post_class = true;

    // Loop through the cart items to check for the shipping class
    foreach (WC()->cart->get_cart() as $cart_item) {
        $product = $cart_item['data'];
        $shipping_class = $product->get_shipping_class();

        // Debug: Log the product shipping class
        if (defined('WP_DEBUG') && WP_DEBUG) {
            error_log('Product ID: ' . $product->get_id() . ' - Shipping Class: ' . $shipping_class);
        }

        // Check if the product is not the "Canada Post" shipping class
        if ($shipping_class !== 'canada-post') {
            $is_canada_post_class = false;
            break; // No need to check further
        }
    }

    // If no products have the "Canada Post" shipping class, remove the shipping method
    if (!$is_canada_post_class) {
        foreach ($rates as $rate_key => $rate) {
            if ($rate->get_method_id() === 'canada_post_shipping_by_nosites_left') {
                unset($rates[$rate_key]);
                if (defined('WP_DEBUG') && WP_DEBUG) {
                    error_log('Canada Post shipping method removed: ' . $rate->get_label());
                }
            }
        }
    } else {
        if (defined('WP_DEBUG') && WP_DEBUG) {
            error_log('Canada Post shipping method remains available.');
        }
    }

    return $rates;
}
