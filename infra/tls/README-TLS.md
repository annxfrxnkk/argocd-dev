# Wildcard SSL Certificate Management

## Overview
Wildcard SSL certificates are used across multiple services for *.scigames.at domains.

## Certificate Files
Location on cluster: `/root/k8s/*.scigames.at/`

- wildcard-scigames.crt - Combined certificate chain (leaf + intermediate)
- sgi-wildcard-hosteurope-neu.crt - Leaf certificate
- sgi-wildcard-hosteurope-intermediate.crt - Intermediate certificate
- sgi-wildcard-hosteurope-neu.key - Private key

## Namespaces Using Wildcard Certificate
- awx - awx.scigames.at
- harbor - harbor.scigames.at
- vault - vault.scigames.at
- longhorn-system - long.scigames.at
- filebrowser - files.scigames.at
- seaweedfs - s3.scigames.at

## Updating Certificates

### Quick Update (All Namespaces)
Run the automated script:
  ./update-wildcard-cert.sh

### Manual Update Steps

1. Replace certificate files in `/root/k8s/*.scigames.at/`
   - Replace sgi-wildcard-hosteurope-neu.crt
   - Replace sgi-wildcard-hosteurope-intermediate.crt
   - Replace sgi-wildcard-hosteurope-neu.key

2. Rebuild the combined certificate chain:
   cd /root/k8s/*.scigames.at
   cat sgi-wildcard-hosteurope-neu.crt sgi-wildcard-hosteurope-intermediate.crt > wildcard-scigames.crt

3. Update secrets in each namespace:
   kubectl -n <namespace> create secret tls wildcard-scigames \
     --cert=/root/k8s/*.scigames.at/wildcard-scigames.crt \
     --key=/root/k8s/*.scigames.at/sgi-wildcard-hosteurope-neu.key \
     --dry-run=client -o yaml | kubectl apply -f -

4. Verify the update:
   kubectl get secrets --all-namespaces | grep wildcard-scigames
   kubectl get ingress --all-namespaces

## Ingress Configuration Files

TLS is configured in the following ingress resources:
- `apps/manifests/vault/vault-ingress.yaml`
- `apps/manifests/awx/awx.yml`
- `apps/helm/harbor/values.yaml` (Harbor Helm chart manages ingress)
- `apps/manifests/longhorn/longhorn-ingress.yml`
- `apps/manifests/filebrowser/filebrowser.yml`
- `apps/manifests/seaweedfs/seaweedfs-ingress.yaml`

## SSL Redirect Configuration
Traefik handles HTTP-to-HTTPS redirect globally via the `web` entrypoint
redirect in `apps/helm/traefik/values.yaml`. No per-ingress annotation needed.

## Certificate Expiry
Monitor certificate expiry using:
  openssl x509 -enddate -noout -in /root/k8s/*.scigames.at/wildcard-scigames.crt
