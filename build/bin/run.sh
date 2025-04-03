#!/bin/bash

chown www-data:www-data /srv/bedrock/web/app/uploads/
#chown www-data:www-data /srv/bedrock/web/app/plugins/

/usr/bin/supervisord -c /etc/supervisord.conf
