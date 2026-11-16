#!/bin/bash


# Work from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")"
echo "################################################################"
echo "#                                                              #"
echo "# DANGER: This script will stop and remove all CxO containers, #"
echo "#         networks, and volumes of this stack, then            #"
echo "#         reset this folder: .env and certs/ are deleted too.  #"
echo "#                                                              #"
echo "#         ALL CxO DATA AND HISTORY WILL BE LOST                #"
echo "#                                                              #"
echo "################################################################"
echo 

confirmation() {
    while true; do
        read -p "Do you want to proceed (yes/no): " choice
        case "$choice" in
            yes|YES)
                return 0 
                ;;
            no|NO)
                return 1
                ;;
            *)
                echo "Invalid response. Please enter 'yes' or 'no'."
                ;;
        esac
    done
}

if confirmation; then
    echo "Stopping and removing containers, networks, and volumes of this stack..."
    if ! docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down --volumes; then
        echo "Docker cleanup failed; the working folder was not reset."
        exit 1
    fi
    echo "Docker cleanup complete."
    echo "Resetting the working folder..."
    git reset --hard HEAD && git clean -dfx
    echo "Factory reset complete."
else 
    echo "Nothing to do."
fi
