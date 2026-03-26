#!/bin/bash
APP_ID="72b76b00-77a9-4685-aaa7-10d2fd5d9df4"
SUBSCRIPTION_ID="deff16bb-1070-4edc-8885-e314b6fef455"
RG_NAME="rg-learning-k8s"

SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME"

#azure cli command to create resource group RG_NAME
az group create --name $RG_NAME --location "eastus" && \

# Role 1
az role assignment create \
  --role "Contributor" \
  --assignee $APP_ID \
  --scope $SCOPE && \

# Role 2
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $APP_ID \
  --scope $SCOPE && \

# Role 3 (example)
az role assignment create \
  --role "Reader" \
  --assignee $APP_ID \
  --scope $SCOPE
