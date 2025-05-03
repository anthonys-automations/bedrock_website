#!/bin/bash

chown www-data:www-data /srv/bedrock/web/app/
chown www-data:www-data /srv/bedrock/web/app/uploads/
#chown www-data:www-data /srv/bedrock/web/app/plugins/
mkdir -p /srv/bedrock/web/app/plugins/independent-analytics/temp/
chown www-data:www-data /srv/bedrock/web/app/plugins/independent-analytics/temp/

openssl req -x509 -newkey rsa:4096 -keyout /etc/nginx/server.key -out /etc/nginx/server.crt -sha256 -days 3650 -nodes -subj "/CN=${SITE_NAME}"
cp /etc/nginx/server.crt /usr/local/share/ca-certificates/ && update-ca-certificates
echo "127.0.1.1 ${SITE_NAME}" >> /etc/hosts

/usr/bin/supervisord -c /etc/supervisord.conf
