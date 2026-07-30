# Apache variant of the official PHP image: PHP runs as mod_php inside Apache,
# so the container has a single process and needs no supervisord, no nginx and
# no hand-tuned FPM pool.
#
# Pinned to an explicit PHP release instead of the floating `8.2-apache` tag so
# builds are reproducible and base image bumps are proposed and reviewed by
# Renovate (see renovate.json / docs/image-versioning.md) rather than arriving
# silently on the next rebuild.
FROM php:8.5.8-apache AS base
LABEL name=bedrock
LABEL intermediate=true

# Install essential packages
RUN apt-get update \
  && apt-get install -y \
    build-essential \
    curl \
    git \
    gnupg \
    less \
    nano \
    vim \
    unzip \
    zip \
  && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get clean

FROM base AS php
LABEL name=bedrock
LABEL intermediate=true

# Install php extensions and related packages.
#
# redis is here for the PromPress plugin: it stores its Prometheus counters in
# Redis and disables itself outright (admin notice only) when the PECL
# extension is missing, so this is a hard requirement rather than a
# performance option. See the Telemetry section of the README.
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && sync \
  && install-php-extensions \
    @composer \
    exif \
    gd \
    imagick \
    intl \
    memcached \
    mysqli \
    opcache \
    pcntl \
    pdo_mysql \
    redis \
    zip \
    gmp \
    bcmath \
  && apt-get update \
  && apt-get install -y \
    gifsicle \
    jpegoptim \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libmemcached-dev \
    locales \
    lua-zlib-dev \
    optipng \
    pngquant \
  && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get clean

FROM php AS bedrock
LABEL name=bedrock

# Node/yarn are for building themes, not for serving traffic.
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash \
  && apt-get update \
  && apt-get install -y \
    nodejs \
  && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get clean \
  && npm install -g yarn

# rewrite: WordPress front controller. headers: the security response headers
# previously added by nginx. ssl: the loopback-only HTTPS vhost on 443.
# status: the mod_status endpoint a Prometheus exporter sidecar scrapes.
# Everything else (MPM, keep-alive, process recycling) stays at upstream
# defaults - avoiding bespoke tuning is the point of this image layout.
# The last line removes a symlink the base image creates: it points
# /var/log/apache2/access.log at /dev/stdout so the stock vhost's access log
# shows up in `docker logs`. This image logs *errors* to stderr and access lines
# to a rotatelogs-managed file at that same path, so the symlink has to go -
# left in place, rotatelogs writes every request onto the container's stdout,
# the 3x50M cap silently never applies (a character device never grows), and the
# file looks present even when ACCESS_LOG=off. Symptom when it regressed: the
# validation workflow failed on `test -s /var/log/apache2/access.log`.
COPY ./build/apache/bedrock.conf /etc/apache2/sites-available/bedrock.conf
RUN a2enmod rewrite headers ssl status \
  && a2dissite 000-default \
  && a2ensite bedrock \
  && a2disconf other-vhosts-access-log \
  && rm -f /var/log/apache2/access.log

COPY ./build/bin/run.sh /run.sh
COPY ./build/php/php.ini /usr/local/etc/php/conf.d/php.ini

COPY ./bedrock /srv/bedrock
# /var/log/php is gone with PHP-FPM: mod_php writes to Apache's error log,
# which the vhost sends to the container's stderr.
RUN cd /srv/bedrock \
  && composer update \
  && chmod +x /run.sh

# Build-time provenance: the Git commit this image was built from, so a running
# container can be traced back to source for audit (`docker exec <c> printenv
# GIT_COMMIT`). Kept as an env var and not only as an OCI label so it is
# readable from inside the container, and declared after the package/composer
# layers so a new commit does not invalidate them. Treat it as best-effort: it
# is only accurate for builds made from a clean working tree, and the immutable
# image digest remains the authoritative audit record.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

# Probe Apache itself rather than WordPress: a database outage can make `/`
# return 500 even though the web process is healthy. Kubernetes should use its
# own readiness probe when application availability must gate traffic.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS -o /dev/null 'http://127.0.0.1:8081/server-status?auto' || exit 1

WORKDIR /srv/bedrock
CMD ["/run.sh"]
