apt install composer
apt install php-curl
apt install php-xml
apt install apache2
apt install libapache2-mod-php
apt install php-mysql

composer create-project roots/bedrock
composer update

#apt install mariadb-server
#mysql -u root

#create database wp;
#create user bedrock identified by 'REDACTED';
#grant all on wp.* to bedrock ;
