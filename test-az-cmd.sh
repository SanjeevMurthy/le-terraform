# variables
RG="rg-learning-k8s"
SP_NAME="gh-actions-sp"

# create resource group (skip if exists)
#az group create -n $RG -l eastus

# create service principal with role assignment to the resource group
az ad sp create-for-rbac \
  --name "$SP_NAME" \
  --role "Contributor" \
  --scopes "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG" \
  --sdk-auth
