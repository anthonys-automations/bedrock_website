<?php get_header(); ?>
<div class="hero">
  <img src="<?php echo get_template_directory_uri(); ?>/assets/images/hero-bg.png">
  <div class="hero-text">
    <h1><?php echo get_theme_mod('hero_heading', 'Great Finds Await'); ?></h1>
    <p><?php echo get_theme_mod('hero_subtext', 'Quality pre-loved items at great prices.'); ?></p>
    <a href="/shop" class="cta-button">Shop Now</a>
  </div>
</div>
<?php get_footer(); ?>
