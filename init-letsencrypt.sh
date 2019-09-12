#!/bin/bash

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

domains=(calendz.app www.calendz.app api.calendz.app api-calendar.calendz.app git.calendz.app github.calendz.app) # ci.calendz.app
rsa_key_size=4096
data_path="./nginx/data/certbot"
email="dufourarthur.perso@gmail.com"
staging=0

if [ -d "$data_path" ]; then
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi


if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

for domain in "${domains[@]}"; do
  echo "### Removing old certificate for $domain ..."
  docker-compose -f docker/docker-compose.prod.yml run --rm --entrypoint "\
    rm -Rf /etc/letsencrypt/live/$domain && \
    rm -Rf /etc/letsencrypt/archive/$domain && \
    rm -Rf /etc/letsencrypt/renewal/$domain.conf" calendz-certbot
  echo
done

for domain in "${domains[@]}"; do
  echo "### Creating dummy certificate for $domain ..."
  path="/etc/letsencrypt/live/$domain"
  mkdir -p "$data_path/conf/live/$domain"
  docker-compose -f docker/docker-compose.prod.yml run --rm --entrypoint "\
    openssl req -x509 -nodes -newkey rsa:1024 -days 1\
      -keyout "$path/privkey.pem" \
      -out "$path/fullchain.pem" \
      -subj '/CN=localhost'" calendz-certbot
  echo
done

echo "### Starting nginx ..."
docker-compose -f docker/docker-compose.prod.yml up --force-recreate -d
echo

for domain in "${domains[@]}"; do
  echo "### Removing dummy certificate for $domain ..."
  docker-compose -f docker/docker-compose.prod.yml run --rm --entrypoint "\
    rm -Rf /etc/letsencrypt/live/$domain" calendz-certbot
  echo
done

echo "### Requesting Let's Encrypt certificates ..."

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

for domain in "${domains[@]}"; do
  docker-compose -f docker/docker-compose.prod.yml run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      $staging_arg \
      $email_arg \
      -d $domain \
      --rsa-key-size $rsa_key_size \
      --agree-tos \
      --force-renewal" calendz-certbot
  echo
done

echo "### Reloading nginx ..."
docker-compose -f docker/docker-compose.prod.yml exec calendz-nginx nginx -s reload