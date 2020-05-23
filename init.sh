#!/bin/bash

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

domains=$domain_names
rsa_key_size=2048
data_path="./data/certbot"
email=$certbot_email # Adding a valid address is strongly recommended
staging=0 # Set to 1 if you're testing your setup to avoid hitting request limits

### always overwrie the existing data
#if [ -d "$data_path" ]; then
#  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
#  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
#    exit
#  fi
#fi


if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s \
  https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx-tls13-session-tix-on.conf \
  > "$data_path/conf/options-ssl-nginx.conf"
  openssl dhparam -out "$data_path/conf/ssl-dhparams.pem" 2048
  echo
fi

echo "### Checking if there is a valid certificate to avoid request limit..."
if [ -f ./data/certbot/conf/live/$domains/cert.pem ]; then
  days=$(( ($(date --date="$(openssl x509 -in ./data/certbot/conf/live/$domains/cert.pem -noout -dates  | grep notAfter | awk '{print $1,$2,$4}'| cut -b 10-14,15-)" "+%s") - $(date '+%s')) / 86400))
  cn=$(openssl x509 -noout -in ./data/certbot/conf/live/$domains/cert.pem -subject | cut -b 14-)
  if [ $cn = $domains ] && [ $days > 10 ]; then
    echo "No need for new certificate"
    no_new_cert=true
  fi
fi

if [ "$no_new_cert" != "true" ]; then
  echo "### Creating dummy certificate for $domains ..."
  path="/etc/letsencrypt/live/$domains"
  mkdir -p "$data_path/conf/live/$domains"
  docker-compose run --rm --entrypoint "\
    openssl req -x509 -nodes -newkey rsa:1024 -days 1\
      -keyout '$path/privkey.pem' \
      -out '$path/fullchain.pem' \
      -subj '/CN=localhost'" certbot
  echo
fi

echo "### Starting nginx ..."
docker-compose up --force-recreate -d nginx
echo

if [ "$no_new_cert" != "true" ]; then
  echo "### Deleting dummy certificate for $domains ..."
  docker-compose run --rm --entrypoint "\
    rm -Rf /etc/letsencrypt/live/$domains && \
    rm -Rf /etc/letsencrypt/archive/$domains && \
    rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
  echo


  echo "### Requesting Let's Encrypt certificate for $domains ..."
  domain_args="-d $domains"

  # Select appropriate email arg
  case "$email" in
    "") email_arg="--register-unsafely-without-email" ;;
    *) email_arg="--email $email" ;;
  esac

  # Enable staging mode if needed
  if [ $staging != "0" ]; then staging_arg="--staging"; fi

  docker-compose run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --noninteractive \
    --no-eff-email \
    --force-renewal" certbot
  echo

  echo "### Reloading nginx ..."
  docker-compose exec nginx nginx -s reload
  echo 
fi


echo "### Starting certbot in renew mode ..."
docker-compose up -d certbot
echo
