#!/bin/bash
set -euo pipefail

# Script to update wildcard SSL certificate across all namespaces
# that have Ingress resources referencing wildcard-scigames.

CERT_PATH="/root/k8s/*.scigames.at"
CERT_CRT="$CERT_PATH/wildcard-scigames.crt"
CERT_KEY="$CERT_PATH/sgi-wildcard-hosteurope-neu.key"

# Every namespace with an Ingress that uses wildcard-scigames TLS secret
NAMESPACES=("awx" "harbor" "vault" "longhorn-system" "filebrowser" "seaweedfs")

echo "Updating wildcard SSL certificate across all namespaces..."
echo ""

for NAMESPACE in "${NAMESPACES[@]}"; do
    echo "Updating certificate in namespace: $NAMESPACE"
    if kubectl -n "$NAMESPACE" create secret tls wildcard-scigames \
        --cert="$CERT_CRT" \
        --key="$CERT_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        echo "  Certificate updated successfully in $NAMESPACE"
    else
        echo "  Failed to update certificate in $NAMESPACE"
        exit 1
    fi
    echo ""
done

echo "Certificate update completed for all namespaces!"
echo ""
echo "Verifying secrets..."
kubectl get secrets --all-namespaces | grep wildcard-scigames
