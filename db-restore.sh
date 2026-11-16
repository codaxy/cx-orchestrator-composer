#!/bin/bash

# Check if the filename is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <filename.sql or filename.sql.gz>"
    exit 1
fi

# Assign the input filename to a variable
FILE="$1"

if [[ "$FILE" == *.gz ]]; then
    # Check if gunzip is installed
    if ! command -v gunzip &> /dev/null; then
        echo "Error: gunzip is not installed. Please install gunzip to process .gz files."
        exit 1
    fi
    # Use gunzip -c to decompress and pipe to docker exec
    gunzip -c "$FILE" | docker exec -i cxo-db psql -U postgres
else
    # Directly pipe the file if it's not .gz
    cat "$FILE" | docker exec -i cxo-db psql -U postgres
fi
