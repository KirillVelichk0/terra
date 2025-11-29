#!/bin/bash
set -e

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx php-fpm php-mysql wget unzip mysql-client

cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 8080 default_server;
    root /var/www/html;
    index index.php index.html index.htm;
    server_name _;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF
systemctl restart nginx

# Загрузка WordPress
cd /var/www
if [ ! -d html/wp-admin ]; then
  rm -rf html
  wget https://wordpress.org/latest.zip -O /tmp/wp.zip
  unzip /tmp/wp.zip -d /var/www
  mv /var/www/wordpress /var/www/html
  chown -R www-data:www-data /var/www/html
fi

export WP_CONFIG_CONTENT=$(cat <<EOF
<?php
define('DB_NAME', '${wp_db_name}');
define('DB_USER', '${wp_db_user}');
define('DB_PASSWORD', '${wp_db_pass}');
define('DB_HOST', '${wp_db_host}:${wp_db_port}');
\$table_prefix = 'wp_';
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');
define('AUTH_KEY',         'change_me');
define('SECURE_AUTH_KEY',  'change_me');
define('LOGGED_IN_KEY',    'change_me');
define('NONCE_KEY',        'change_me');
define('AUTH_SALT',        'change_me');
define('SECURE_AUTH_SALT', 'change_me');
define('LOGGED_IN_SALT',   'change_me');
define('NONCE_SALT',       'change_me');
define('WP_DEBUG', false);
if ( !defined('ABSPATH') ) define('ABSPATH', dirname(__FILE__) . '/');
require_once(ABSPATH . 'wp-settings.php');
EOF
)
echo "$WP_CONFIG_CONTENT" > /var/www/html/wp-config.php

chown www-data:www-data /var/www/html/wp-config.php
systemctl restart php7.4-fpm || systemctl restart php8.1-fpm || true

