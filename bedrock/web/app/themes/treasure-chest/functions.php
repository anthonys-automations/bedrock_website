<?php
function treasurechest_setup() {
  add_theme_support('title-tag');
  add_theme_support('post-thumbnails');
  add_theme_support('woocommerce');
  register_nav_menus([
    'primary' => __('Primary Menu'),
  ]);
}
add_action('after_setup_theme', 'treasurechest_setup');

function treasurechest_scripts() {
  wp_enqueue_style('main-style', get_stylesheet_uri());
}
add_action('wp_enqueue_scripts', 'treasurechest_scripts');

function treasurechest_customize_register($wp_customize) {
  $wp_customize->add_section('hero_section', [
    'title' => __('Hero Section', 'treasurechest'),
    'priority' => 30,
  ]);

  $wp_customize->add_setting('hero_heading', [
    'default' => 'Great Finds Await',
    'sanitize_callback' => 'sanitize_text_field',
  ]);
  $wp_customize->add_control('hero_heading', [
    'label' => __('Hero Heading', 'treasurechest'),
    'section' => 'hero_section',
    'type' => 'text',
  ]);

  $wp_customize->add_setting('hero_subtext', [
    'default' => 'Quality pre-loved items at great prices.',
    'sanitize_callback' => 'sanitize_text_field',
  ]);
  $wp_customize->add_control('hero_subtext', [
    'label' => __('Hero Subtext', 'treasurechest'),
    'section' => 'hero_section',
    'type' => 'text',
  ]);
}
add_action('customize_register', 'treasurechest_customize_register');
?>
