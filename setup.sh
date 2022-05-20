##################################################
##
## creates a private data fusion instance and static
## cdf cluster in an existing project.
## run as a user that can modify org policies in
## the project.  Works in argolis.
##
##################################################


##################################################
##
## Variables needed upfront
##
##################################################
# project id for the existing project you want to deploy into
PROJECT_ID=my-awesome-project-01

# these can be left as default
REGION=us-central1
ZONE=us-central1-a
VPC_NAME=demo-vpc
SUBNET_NAME=demo-subnet-1


##################################################
##
## configure org policies
##
##################################################

echo "configuring org policies for argolis envs"

cat <<EOF > new_policy.yaml
constraint: constraints/compute.vmExternalIpAccess
listPolicy:
    allValues: ALLOW
EOF
gcloud resource-manager org-policies set-policy  \
    --project=${PROJECT_ID} new_policy.yaml

cat <<EOF > new_policy.yaml
constraint: constraints/compute.restrictVpcPeering
listPolicy:
    allValues: ALLOW
EOF
gcloud resource-manager org-policies set-policy \
    --project=${PROJECT_ID} new_policy.yaml

gcloud resource-manager org-policies disable-enforce \
    compute.requireShieldedVm --project=${PROJECT_ID}

##################################################
##
## enable APIs
##
##################################################

echo "enabling APIs"

gcloud config set project ${PROJECT_ID}

gcloud services enable compute.googleapis.com

gcloud services enable dataflow.googleapis.com

gcloud services enable pubsub.googleapis.com

gcloud services enable storage.googleapis.com

gcloud services enable bigquery.googleapis.com

gcloud services enable datafusion.googleapis.com

#for private service connection
gcloud services enable servicenetworking.googleapis.com

gcloud services enable sqladmin.googleapis.com

##################################################
##
## Create VPC Network and subnet
##
##################################################

echo "creating a VPC Network"

gcloud compute networks create ${VPC_NAME} \
--project=${PROJECT_ID} \
--subnet-mode=custom \
--mtu=1460 \
--bgp-routing-mode=regional

echo "Creating a subnet"

gcloud compute networks subnets create ${SUBNET_NAME} \
--range=10.100.0.0/20 \
--network=${VPC_NAME} \
--region=${REGION} \
--enable-private-ip-google-access

##################################################
##
## Create FW rules
##
##################################################

echo "configuring firewall rules"

#allow all internal
gcloud compute firewall-rules create allow-all-internal \
--direction=INGRESS \
--priority=1000 \
--network=${VPC_NAME} \
--action=ALLOW \
--rules=all \
--source-ranges=10.100.0.0/20

#allow SSH via IAP
gcloud compute firewall-rules create allow-ssh-ingress-from-iap \
--direction=INGRESS \
--action=allow \
--rules=tcp:22 \
--source-ranges=35.235.240.0/20 \
--network=${VPC_NAME}

gcloud compute firewall-rules create fusion-allow-ssh \
--direction=INGRESS \
--priority=1000 \
--network=${VPC_NAME} --action=ALLOW --rules=tcp:22 --source-ranges=192.168.0.0/22

##################################################
##
## Create Cloud Nat
##
##################################################

echo "configuring cloud nat"


gcloud compute routers create nat-router \
    --network ${VPC_NAME} \
    --region ${REGION}

 gcloud compute routers nats create nat-config \
    --router-region ${REGION} \
    --router nat-router \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips   


##################################################
##
## Create a private CDF instance with peering
##
##################################################

echo "creating address range for data fusion tenant project"


gcloud compute addresses create datafusion-tenant-project-ips \
    --global \
    --purpose=VPC_PEERING \
    --addresses=192.168.0.0 \
    --prefix-length=22 \
    --description="Data Fusion Tenant Project IP Range" \
    --network=${VPC_NAME}
    
echo "creating a private CDF cluster, this command is asynchronous"


CDF_INSTANCES_API=https://datafusion.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/instances

curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
   -H "Content-Type: application/json" \
   ${CDF_INSTANCES_API}?instance_id=cdf-dev-private \
   -X POST -d \
   '{"description": "Private CDF", "type": "DEVELOPER", "privateInstance": true, "networkConfig": {"network": "'${VPC_NAME}'", "ipAllocation": "192.168.0.0/22"}}'

echo "fusion instance job creation job submitted.  review the above for errors"

echo "sleeping for 15 minutes to wait for cluster completion"

echo `date`

sleep 15m

echo "looking up the tenant project number"

PROJECT_NUM=`gcloud projects list \
    --filter="$(gcloud config get-value project)" \
    --format="value(PROJECT_NUMBER)"`

TENANT_PROJECT_ID=`curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
   -H "Content-Type: application/json" \
   ${CDF_INSTANCES_API}/cdf-dev-private \
   | jq -r '.tenantProjectId'`

echo "creating network peering between VPC and tenant project"

gcloud compute networks peerings create data-fusion-peering \
    --peer-project=${TENANT_PROJECT_ID} \
    --network=${VPC_NAME}  \
    --peer-network=${REGION}-data-fusion-dev-private  \
    --export-custom-routes --import-custom-routes 


##################################################
##
## Give default compute engine service account
## edit rights to project and allow CDF service
## account to run as the default compute service
## account
##
##################################################

echo "configuring permissons for compute and data fusion service accounts"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member=serviceAccount:${PROJECT_NUM}-compute@developer.gserviceaccount.com \
    --role=roles/editor

gcloud iam service-accounts add-iam-policy-binding \
    ${PROJECT_NUM}-compute@developer.gserviceaccount.com \
    --member=serviceAccount:service-${PROJECT_NUM}@gcp-sa-datafusion.iam.gserviceaccount.com \
    --role=roles/iam.serviceAccountUser


##################################################
##
## create static dataproc cluster for fusion
## 
##
##################################################

echo "creating static dataproc cluster"


  gcloud dataproc clusters create cdf-static-cluster \
  --enable-component-gateway \
  --region ${REGION} \
  --subnet ${SUBNET_NAME} \
  --no-address \
  --zone ${ZONE} \
  --master-machine-type n1-standard-4 \
  --master-boot-disk-size 500 \
  --num-workers 2 \
  --worker-machine-type n1-standard-4 \
  --worker-boot-disk-size 500 \
  --image-version 2.0.28-debian10 \
  --properties yarn:nodemanager.delete.debug-delay-sec=86400,yarn:nodemanager.pmem-check-enabled=false,yarn:nodemanager.vmem-check-enabled=false \
  --scopes 'https://www.googleapis.com/auth/cloud-platform'   


