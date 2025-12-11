<VirtualHost *:80>
    ServerName {{FQDN}}
    ErrorLog /var/www/{{CERT_DOMAIN}}/{{SUBDOMAIN}}/log/error.log
    CustomLog /var/www/{{CERT_DOMAIN}}/{{SUBDOMAIN}}/log/access.log combined
</VirtualHost>
