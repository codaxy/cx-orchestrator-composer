#!/bin/bash


# Work from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")"
echo "######################################################"
echo "#                                                    #"
echo "# DANGER: This script will remove all CxO databases  #"
echo "#                                                    #"
echo "#         ALL CxO DATA WILL BE LOST                  #"
echo "#                                                    #"
echo "######################################################"
echo 


read -p "Are you sure you want to proceed (yes/no): " choice
if [[ $choice != "yes" && $choice != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

docker compose -f docker-compose.db.yml down --volumes
docker compose -f docker-compose.db.yml up -d
