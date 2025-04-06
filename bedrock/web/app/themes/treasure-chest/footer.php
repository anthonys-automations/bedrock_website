<footer>
  <p>&copy; <?php echo date('Y'); ?> Treasure Chest. All rights reserved.</p>
</footer>
<?php wp_footer(); ?>
<script>
  document.addEventListener('DOMContentLoaded', function () {
    const toggle = document.querySelector('.menu-toggle');
    const menu = document.querySelector('nav ul');

    if (toggle && menu) {
      toggle.addEventListener('click', () => {
        menu.classList.toggle('active');
      });
    }
  });
</script>
</body>
</html>
