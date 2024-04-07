#!/bin/bash
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/C=US/ST=MI/L=Romulus/O=RMIITools/CN=localhost" \
    -keyout server.key -out server.crt
