# ---------------------------------------------------------------------------
# Remote state in a GCS bucket
# ---------------------------------------------------------------------------
# Deliberately EMPTY ("partial configuration"). The bucket name is not a
# secret, but hard-coding it means this file cannot be reused and every
# contributor must edit it. Instead we pass it at init time:
#
#   terraform init \
#     -backend-config="bucket=$TF_STATE_BUCKET" \
#     -backend-config="prefix=linkforge"
#
# This is the same pattern as the Azure stack in this repo.
terraform {
  backend "gcs" {}
}
