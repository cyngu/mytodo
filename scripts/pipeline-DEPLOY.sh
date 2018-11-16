#!/bin/bash
source ./scripts/pipeline-HELPER.sh

#
# Set environments to good default values in case we are not running from the toolchain but interactively
#
section "Environment"

if [ -z "$REGION" ]; then
  export REGION=$(ibmcloud target | grep Region | awk '{print $2}')
fi
echo "REGION=$REGION"

if [ -z "$PIPELINE_KUBERNETES_CLUSTER_NAME" ]; then
  echo 'PIPELINE_KUBERNETES_CLUSTER_NAME was not set. Set it to the target cluster name.'
  exit 1;
fi
echo "PIPELINE_KUBERNETES_CLUSTER_NAME=$PIPELINE_KUBERNETES_CLUSTER_NAME"

if [ -z "$TARGET_RESOURCE_GROUP" ]; then
  TARGET_RESOURCE_GROUP=default
fi
echo TARGET_RESOURCE_GROUP=$TARGET_RESOURCE_GROUP

if [ -z "$TARGET_NAMESPACE" ]; then
  export TARGET_NAMESPACE=default
fi
echo "TARGET_NAMESPACE=$TARGET_NAMESPACE"

if [ -z "$COS_PLAN" ]; then
  export COS_PLAN=lite
fi
echo "COS_PLAN=$COS_PLAN"

if [ -z "$APP_ID_PLAN" ]; then
  export APP_ID_PLAN=lite
fi
echo "APP_ID_PLAN=$APP_ID_PLAN"

#
# Set target
#
ibmcloud target -g $TARGET_RESOURCE_GROUP || exit 1

#
# The user running the script will be used to name some resources
#
TARGET_USER=$(ibmcloud target | grep User | awk '{print $2}')
check_value "$TARGET_USER"
echo "TARGET_USER=$TARGET_USER"

#
# Create Service ID
#
section "Service ID"
if check_exists "$(ibmcloud iam service-id secure-file-storage-serviceID-$TARGET_USER)"; then
  echo "Service ID already exists"
else
  ibmcloud iam service-id-create "secure-file-storage-serviceID-$TARGET_USER" -d "serviceID for secure file storage tutorial"
fi
SERVICE_ID=$(ibmcloud iam service-id "secure-file-storage-serviceID-$TARGET_USER" --uuid)
echo "SERVICE_ID=$SERVICE_ID"
check_value "$SERVICE_ID"

#
# Key Protect
#
section "Key Protect"
if check_exists "$(ibmcloud resource service-instance secure-file-storage-kms)"; then
  echo "Key Protect service already exists"
else
  ibmcloud resource service-instance-create secure-file-storage-kms kms tiered-pricing $REGION || exit 1
fi
KP_INSTANCE_ID=$(get_instance_id secure-file-storage-kms)
KP_GUID=$(get_guid secure-file-storage-kms)
echo "KP_INSTANCE_ID=$KP_INSTANCE_ID"
echo "KP_GUID=$KP_GUID"
check_value "$KP_INSTANCE_ID"
check_value "$KP_GUID"

if check_exists "$(ibmcloud resource service-key secure-file-storage-kms-acckey-$KP_GUID)"; then
  echo "Key Protect key already exists"
else
  ibmcloud resource service-key-create secure-file-storage-kms-acckey-$KP_GUID Manager \
    --instance-id "$KP_INSTANCE_ID" || exit 1
fi

if (ibmcloud iam service-policies $SERVICE_ID | grep -q "No policy found" ); then
  EXISTING_POLICIES="[]"
else
  EXISTING_POLICIES=$(ibmcloud iam service-policies $SERVICE_ID --output json | grep -v -e "^OK")
fi
echo "EXISTING_POLICIES=$EXISTING_POLICIES"
check_value "$EXISTING_POLICIES"

# Create a policy to make serviceID a writer for Key Protect
if echo "$EXISTING_POLICIES" | \
  jq -e -r 'select(.resources[].serviceInstance=="'$KP_GUID'" and .roles[].displayName=="Writer")' > /dev/null; then
  echo "Writer policy on Key Protect already exist for the Service ID"
else
  ibmcloud iam service-policy-create $SERVICE_ID -r Writer --service-instance $KP_GUID --force
fi

KP_CREDENTIALS=$(ibmcloud resource service-key secure-file-storage-kms-acckey-$KP_GUID)
KP_IAM_APIKEY=$(echo "$KP_CREDENTIALS" | sort | grep "apikey:" -m 1 | awk '{ print $2 }')
KP_ACCESS_TOKEN=$(get_access_token $KP_IAM_APIKEY)
KP_MANAGEMENT_URL="https://keyprotect.$REGION.bluemix.net/api/v2/keys"

# Create root key if it does not exist
KP_KEYS=$(curl -s $KP_MANAGEMENT_URL \
  --header "Authorization: Bearer $KP_ACCESS_TOKEN" \
  --header "Bluemix-Instance: $KP_GUID")
check_value "$KP_KEYS"

if echo $KP_KEYS | jq -e -r '.resources[] | select(.name=="secure-file-storage-root-enckey")' > /dev/null; then
  echo "Root key already exists"
else
  KP_KEYS=$(curl -s -X POST $KP_MANAGEMENT_URL \
    --header "Authorization: Bearer $KP_ACCESS_TOKEN" \
    --header "Bluemix-Instance: $KP_GUID" \
    --header "Content-Type: application/vnd.ibm.kms.key+json" -d @scripts/root-enckey.json)
fi
ROOT_KEY_CRN=$(echo $KP_KEYS | jq -e -r '.resources[] | select(.name=="secure-file-storage-root-enckey") | .crn')
echo "ROOT_KEY_CRN=$ROOT_KEY_CRN"

#
# Cloudant instance with IAM authentication
#
section "Cloudant"
if check_exists "$(ibmcloud resource service-instance secure-file-storage-cloudant)"; then
  echo "Cloudant service already exists"
else
  ibmcloud resource service-instance-create secure-file-storage-cloudant \
    cloudantnosqldb lite $REGION \
    -p '{"legacyCredentials": false}' || exit 1
fi
CLOUDANT_INSTANCE_ID=$(get_instance_id secure-file-storage-cloudant)
CLOUDANT_GUID=$(get_guid secure-file-storage-cloudant)
echo "CLOUDANT_INSTANCE_ID=$CLOUDANT_INSTANCE_ID"
echo "CLOUDANT_GUID=$CLOUDANT_GUID"
check_value "$CLOUDANT_INSTANCE_ID"
check_value "$CLOUDANT_GUID"

if check_exists "$(ibmcloud resource service-key secure-file-storage-cloudant-acckey-$CLOUDANT_GUID)"; then
  echo "Cloudant key already exists"
else
  ibmcloud resource service-key-create secure-file-storage-cloudant-acckey-$CLOUDANT_GUID Manager \
    --instance-id "$CLOUDANT_INSTANCE_ID" || exit 1
fi

CLOUDANT_CREDENTIALS=$(ibmcloud resource service-key secure-file-storage-cloudant-acckey-$CLOUDANT_GUID)
CLOUDANT_ACCOUNT=$(echo "$CLOUDANT_CREDENTIALS" | grep "username:" | awk '{ print $2 }')
CLOUDANT_IAM_APIKEY=$(echo "$CLOUDANT_CREDENTIALS" | sort | grep "apikey:" -m 1 | awk '{ print $2 }')
CLOUDANT_URL=$(echo "$CLOUDANT_CREDENTIALS" | grep "url:" -m 1 | awk '{ print $2 }')
CLOUDANT_ACCESS_TOKEN=$(get_access_token $CLOUDANT_IAM_APIKEY)

if [ -z "$CLOUDANT_DATABASE" ]; then
  echo 'CLOUDANT_DATABASE was not set, using default value'
  export CLOUDANT_DATABASE=secure-file-storage-metadata
fi
echo "CLOUDANT_DATABASE=$CLOUDANT_DATABASE"

# Create the database
echo "Creating database"
curl -X PUT \
  -H "Authorization: Bearer $CLOUDANT_ACCESS_TOKEN" \
  "$CLOUDANT_URL/$CLOUDANT_DATABASE"


#
# Deploy our app
#
section "Kubernetes"

INGRESS_SECRET=$(ibmcloud cs cluster-get $PIPELINE_KUBERNETES_CLUSTER_NAME --json | jq -r .ingressSecretName)
echo "INGRESS_SECRET=${INGRESS_SECRET}"
check_value "$INGRESS_SECRET"

if kubectl get namespace $TARGET_NAMESPACE; then
  echo "Namespace $TARGET_NAMESPACE already exists"
else
  echo "Creating namespace $TARGET_NAMESPACE..."
  kubectl create namespace $TARGET_NAMESPACE || exit 1
fi

#
# Bind App ID to the cluster
#
if kubectl get secret binding-secure-file-storage-appid --namespace $TARGET_NAMESPACE; then
  echo "App ID service already bound to namespace"
else
  ibmcloud cs cluster-service-bind \
    --cluster "$PIPELINE_KUBERNETES_CLUSTER_NAME" \
    --namespace "$TARGET_NAMESPACE" \
    --service "$APPID_GUID" || exit 1
fi

#
# Create a secret in the cluster holding the credentials for Cloudant and COS
#
kubectl delete secret secure-file-storage-credentials --namespace "$TARGET_NAMESPACE"
kubectl create secret generic secure-file-storage-credentials \
  --from-literal="cos_endpoint=$COS_ENDPOINT" \
  --from-literal="cos_ibmAuthEndpoint=$COS_IBMAUTHENDPOINT" \
  --from-literal="cos_apiKey=$COS_APIKEY" \
  --from-literal="cos_resourceInstanceId=$COS_RESOURCE_INSTANCE_ID" \
  --from-literal="cos_access_key_id=$COS_ACCESS_KEY_ID" \
  --from-literal="cos_secret_access_key=$COS_SECRET_ACCESS_KEY" \
  --from-literal="cos_bucket_name=$COS_BUCKET_NAME" \
  --from-literal="cloudant_account=$CLOUDANT_ACCOUNT" \
  --from-literal="cloudant_iam_apikey=$CLOUDANT_IAM_APIKEY" \
  --from-literal="cloudant_database=$CLOUDANT_DATABASE" \
  --namespace "$TARGET_NAMESPACE" || exit 1

#
# Create a secret to access the registry
#
if kubectl get secret secure-file-storage-docker-registry --namespace $TARGET_NAMESPACE; then
  echo "Docker Registry secret already exists"
else
  REGISTRY_TOKEN=$(ibmcloud cr token-add --description "secure-file-storage-docker-registry for $TARGET_USER" --non-expiring --quiet)
  kubectl --namespace $TARGET_NAMESPACE create secret docker-registry secure-file-storage-docker-registry \
    --docker-server=${REGISTRY_URL} \
    --docker-password="${REGISTRY_TOKEN}" \
    --docker-username=token \
    --docker-email="${TARGET_USER}" || exit 1
fi

#
# Deploy the app
#

# uncomment the imagePullSecrets
cp secure-file-storage.template.yaml secure-file-storage.yaml
sed -i 's/#      imagePullSecrets:/      imagePullSecrets:/g' secure-file-storage.yaml
sed -i 's/#        - name: $IMAGE_PULL_SECRET/        - name: $IMAGE_PULL_SECRET/g' secure-file-storage.yaml

cat secure-file-storage.yaml | \
  IMAGE_NAME=$IMAGE_NAME \
  INGRESS_SECRET=$INGRESS_SECRET \
  INGRESS_SUBDOMAIN=$INGRESS_SUBDOMAIN \
  IMAGE_PULL_SECRET=secure-file-storage-docker-registry \
  REGISTRY_URL=$REGISTRY_URL \
  REGISTRY_NAMESPACE=$REGISTRY_NAMESPACE \
  TARGET_NAMESPACE=$TARGET_NAMESPACE \
  envsubst \
  | \
  kubectl apply --namespace $TARGET_NAMESPACE -f - || exit 1

echo "Your app is available at https://secure-file-storage.$INGRESS_SUBDOMAIN/"
