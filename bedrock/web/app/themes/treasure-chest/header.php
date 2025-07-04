<!DOCTYPE html>
<html <?php language_attributes(); ?>>
<head>
  <link rel="icon" href="<?php echo get_template_directory_uri(); ?>/assets/images/favicon.ico" type="image/x-icon">
  <meta charset="<?php bloginfo('charset'); ?>">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <?php wp_head(); ?>
</head>
<body <?php body_class(); ?>>
<header>
  <a href="<?php echo esc_url(home_url('/')); ?>">
    <img src="<?php echo get_template_directory_uri(); ?>/assets/images/logo-orange.png" alt="Logo" class="logo">
  </a>
  <nav>
    <?php wp_nav_menu(['theme_location' => 'primary', 'container' => false]); ?>
  </nav>
  <div class="menu-toggle" id="mobile-menu">&#9776;</div>
</header>
