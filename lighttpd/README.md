lighttpd
lighttpd-mod-auth
lighttpd-mod-authn_file
lighttpd-mod-cgi
lighttpd-mod-openssl
lighttpd-mod-proxy
printf "USER:$(openssl passwd -crypt PASSWORD)\n" >> .htpasswd
