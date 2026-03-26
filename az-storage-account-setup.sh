#!/bin/bash

# # run locally after az login & set subscription
# az storage account create -n ks8-cluster-storage -g rg-learning-k8s -l eastus --sku Standard_LRS
# az storage container create --account-name k8s-cluster-container --name tfplans
# az storage account keys list --account-name mytfstateacct -g <rg> --query "[0].value" -o tsv
# # paste the key into GitHub secret TF_STATE_STORAGE_KEY


# 1) create storage account
az storage account create \
  -n ks8clusterstorage \
  -g rg-learning-k8s \
  -l eastus \
  --sku Standard_LRS

# 2) create container
az storage container create \
  --account-name ks8clusterstorage \
  --name tfplans

# 3) list/get account key (not recommended to embed; store in GitHub Secret)
az storage account keys list -g rg-learning-k8s -n ks8clusterstorage --query "[0].value" -o tsv

# # 4) upload a plan (using account key)
# az storage blob upload \
#   --account-name mytfstateacct \
#   --account-key "<ACCOUNT_KEY>" \
#   --container-name tfplans \
#   --name tfplan \
#   --file ./tfplan \
#   --overwrite

# # 5) alternatively generate a SAS token (scoped + time-limited) and use it instead of account key
# az storage blob generate-sas \
#   --account-name mytfstateacct \
#   --container-name tfplans \
#   --name tfplan \
#   --permissions rwdl \
#   --expiry "$(date -u -d '1 hour' '+%Y-%m-%dT%H:%MZ')" \
#   -o tsv