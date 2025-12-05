<VirtualHost *:80>
    ServerName {{FQDN}}
    ServerAlias *.{{FQDN}}
    DocumentRoot /var/www/{{FQDN}}/public_html
    ErrorLog /var/www/{{FQDN}}/log/error.log
    CustomLog /var/www/{{FQDN}}/log/access.log combined
</VirtualHost>
