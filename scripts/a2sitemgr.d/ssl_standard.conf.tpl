<IfModule mod_ssl.c>
    <VirtualHost *:443>
        ServerName {{FQDN}}
        ServerAlias *.{{FQDN}}
        DocumentRoot /var/www/{{FQDN}}/public_html
        ErrorLog /var/www/{{FQDN}}/log/ssl_error.log
        CustomLog /var/www/{{FQDN}}/log/ssl_access.log combined
        SSLEngine on
        SSLCertificateFile /etc/letsencrypt/live/{{FQDN}}/fullchain.pem
        SSLCertificateKeyFile /etc/letsencrypt/live/{{FQDN}}/privkey.pem
    </VirtualHost>
</IfModule>
