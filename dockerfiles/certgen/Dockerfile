# Use Alpine Linux as the base image
FROM alpine:latest

# Install OpenSSL
RUN apk add --no-cache openssl

# Create the /certs directory
RUN mkdir /certs

# Copy the generate-certs.sh script to the container
COPY dockerfiles/certgen/certgen.sh /generate-certs.sh

# Set execute permissions for the script
RUN chmod +x /generate-certs.sh

# Set the script as the ENTRYPOINT
ENTRYPOINT ["/generate-certs.sh"]