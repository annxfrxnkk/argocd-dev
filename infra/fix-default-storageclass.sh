#!/bin/bash
set -euo pipefail

# Fix dual default StorageClass
# K3s marks local-path as default, but Longhorn should be the only default.
# Safe to run multiple times (idempotent).

echo "Removing default annotation from local-path StorageClass..."
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

echo "Verifying single default StorageClass..."
kubectl get storageclass -o custom-columns='NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class'
