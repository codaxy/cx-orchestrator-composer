#!/bin/sh

# Generate a self-signed certificate and private key
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -subj "/O=CxO/CN=cxo" \
    -keyout /certs/privkey.pem \
    -out /certs/cert.pem

# Export the certificate and private key to a PFX file
openssl pkcs12 -export -out /certs/aspnetapp.pfx -inkey /certs/privkey.pem -in /certs/cert.pem -passout pass:password
