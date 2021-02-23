#!/bin/bash




export DEPLOYMENT=""
export GCP_PROJECT_ID=""
export REGION=""
export IP0=""
export IP1=""
export IP2=""
export ADDR0=$IP0
export ADDR1=$IP1
export ADDR2=$IP2



#######################################################
#####             SCRIPT CONFIGS                  #####
#######################################################

function request_env_vars() {
  echo ""
  read -r -p "What is the GCP Project?: " GCP_PROJECT_ID
  read -r -p "What Region is your cluster in?: " REGION
  read -r -p "What would you like your Helm chart to be named?: " DEPLOYMENT
  echo ""
}


#######################################################
#####             CREATION/CLEANUP                #####
#######################################################

function cleanup() {
  while true; do
    read -r -p "Are you sure you want to remove the GCP Resources and Kubernetes Manifests that you have created?: " CONTINUE
    case ${CONTINUE} in
      [Yy]* )
        echo ""
        echo "Removing Kubernetes Manifests..."
        rm -rf manifests/*
        read -r -p "Are you sure you want to remove the Helm installation from the cluster?: " CONTINUE
        case ${CONTINUE} in
          [Yy]* )
            helm_remove
            break
            ;;
          [Nn]* )
            echo ""
            echo "Nothing happened..."
            echo ""
            break
            ;;
          * )
            echo "Please enter Y/y or N/n."
            ;;
        esac
        echo "Deleting GCP Resources that were created..."
        remove_static_ips
        echo ""
        break
        ;;
      [Nn]* )
        echo ""
        echo "Nothing happened..."
        echo ""
        break
        ;;
      * )
        echo "Please enter Y/y or N/n."
        ;;
    esac
  done
}

function standalone() {
  # Standalone (Single Server)
  helm install mygraph ${DEPLOYMENT}-stand . \
    --set core.standalone=true \
    --set acceptLicenseAgreement=yes \
    --set neo4jPassword=mySecretPassword
}

function casual_cluster() {
  # Casual Cluster
  helm install ${DEPLOYMENT} . \
    --set acceptLicenseAgreement=yes \
    --set core.numberOfServers=3 \
    --set readReplica.numberOfServers=0 \
    -f values.yaml

    echo ""
    kubedecode ${DEPLOYMENT}-neo4j-secrets neo
    echo ""
}

#######################################################
#####             EXTERNAL ACCESS                 #####
#######################################################

function get_static_ips() {
  gcloud compute addresses describe neo4j-static-ip-0 --region=${REGION} --project=${GCP_PROJECT_ID} -q
  if [[ $? == "1" ]]; then
    echo "Checking for Static IPs in GCP..."
    create_static_ips
    exit
  fi
  echo ""
  echo "Pulling Static IPs from GCP..."
  echo ""
  export IP0=$(gcloud compute addresses describe neo4j-static-ip-0 --region=${REGION} --project=${GCP_PROJECT_ID} --format=json | jq -r '.address')
  export IP1=$(gcloud compute addresses describe neo4j-static-ip-1 --region=${REGION} --project=${GCP_PROJECT_ID} --format=json | jq -r '.address')
  export IP2=$(gcloud compute addresses describe neo4j-static-ip-2 --region=${REGION} --project=${GCP_PROJECT_ID} --format=json | jq -r '.address')
}

function remove_static_ips() {
  echo ""
  echo "Removing the Static IPs from GCP..."
  echo ""
  gcloud compute addresses delete neo4j-static-ip-0 neo4j-static-ip-1 neo4j-static-ip-2 --region=${REGION} --project=${GCP_PROJECT_ID}
  exit
}

function create_static_ips() {
  echo ""
  echo "Generating Static IPs in GCP..."
  echo ""
  # Customize these next 2 for the region of your GKE cluster, and your GCP project ID
  PROJECT=${GCP_PROJECT_ID}

  for idx in 0 1 2 ; do
     gcloud compute addresses create \
        neo4j-static-ip-$idx --project=$PROJECT \
        --network-tier=PREMIUM --region=$REGION

     CUR_IP=$(gcloud compute addresses describe neo4j-static-ip-$idx \
        --region=$REGION --project=$PROJECT --format=json | jq -r '.address')
     export IP$idx=${CUR_IP}
  done
  echo ""
  echo "neo4j-static-ip-0: $IP0"
  echo "neo4j-static-ip-1: $IP1"
  echo "neo4j-static-ip-2: $IP2"
  echo ""
  exit
}

function elb_manifest_creation() {
  # LoadBalancer Configuration Script.
  # Reuse IP0, etc. from the earlier step here.
  # These *must be IP addresses* and not hostnames, because we're
  # assigning load balancer IP addresses to bind to.
  if [[ $IP0 == "" ]] && [[ $IP1 == "" ]] && [[ $IP2 == "" ]]; then
    get_static_ips
  fi
  export CORE_ADDRESSES=($IP0 $IP1 $IP2)
  # export i=0
  # if [[ ! -d "manifests/external-access" ]]; then
  #   mkdir manifests/external-access
  # fi

  for x in 0 1 2 ; do
     export IDX=$x
     export IP=${CORE_ADDRESSES[$x]}
     echo $DEPLOYMENT with IDX $IDX and IP $IP ;
     cat tools/external-exposure/load-balancer.yaml | envsubst | kubectl apply -f -
     # cat tools/external-exposure/load-balancer.yaml | envsubst > $(pwd)/manifests/external-access/extended-elb-${i}.yaml
     # ((i=i+1))
  done
  echo ""
}

function apply_ext_manifests() {
  if [[ ! -f "manifests/external-access/extended-elb-0.yaml" ]]; then
    elb_manifest_creation
  fi
  echo ""
  echo "Applying the External-Access Kubernetes Manifests..."
  echo ""
  kubectl apply -f $(pwd)/manifests/external-access
  exit
}

function remove_ext_manifests() {
  if [[ ! -f "manifests/external-access/extended-elb-0.yaml" ]]; then
    elb_manifest_creation
  fi
  echo ""
  echo "Removing the External-Access Kubernetes Manifests..."
  echo ""
  kubectl delete -f $(pwd)/manifests/external-access
  echo ""
  echo "Remember you will need to run the remove-static-ips command to delete the GCP resources."
  echo ""
  exit
}

function helm_remove() {
  echo ""
  echo "Removing the Helm installation..."
  echo ""
  helm delete $DEPLOYMENT
  kubectl delete pvc datadir-${DEPLOYMENT}-neo4j-core-0 datadir-${DEPLOYMENT}-neo4j-core-1 datadir-${DEPLOYMENT}-neo4j-core-2
}

function test_shit() {
  set -xe
  export IP0=$(gcloud compute addresses describe neo4j-static-ip-0 --region=${REGION} --project=${GCP_PROJECT_ID} --format=json | jq -r '.address')
  # export IP1=$(gcloud compute addresses describe neo4j-static-ip-1 --region=${REGION} --project=${GCP_PROJECT_ID} --format=json | jq -r '.address')
  # export IP2=$(gcloud compute addresses describe neo4j-static-ip-2 --region=${REGION} --project=${GCP_PROJECT_ID} --format=json | jq -r '.address')
  # Connecting externally.
  export NEO4J_PASSWORD=$(kubectl get secrets ${DEPLOYMENT}-neo4j-secrets -o yaml | grep password | sed 's/.*: //' | base64 -d)
  cypher-shell -a bolt://$IP0:7687 -u neo4j -p "$NEO4J_PASSWORD"
  # cypher-shell -a bolt://$IP1:7687 -u neo4j -p "$NEO4J_PASSWORD"
  # cypher-shell -a bolt://$IP2:7687 -u neo4j -p "$NEO4J_PASSWORD"
}


# Checks for ENV variables being set prior to running the script.
if [[ -z "${GCP_PROJECT_ID}" ]] || [[ -z "${REGION}" ]] || [[ -z "${DEPLOYMENT}" ]]; then
  request_env_vars
fi

echo ""
echo "GCP Project: $GCP_PROJECT_ID"
echo "Region: $REGION"
echo "Deployment Name: $DEPLOYMENT"
echo ""

echo "CLUSTER INFO"
echo ""

kubectx
echo ""
echo ""

echo "NAMESPACE INFO"
echo ""
kubens

echo ""
echo ""
read -r -p 'Are you sure you want to proceed with the installation? ' MOVIN_ON
case $MOVIN_ON in
  [Yy]* )
  echo ""
  echo "Starting the process..."
  echo ""
    ;;
  [Nn]* )
    echo ""
    echo "Nothing happened..."
    echo ""
    exit
    ;;
  * )
    echo "Please enter Y/y or N/n."
    ;;
esac

if [ $# -eq 0 ]; then
  while true; do
    echo ""
    read -r -p 'Please specify one of the following steps:

    casual-cluster        # Runs the helm install command to install a Neo4j Casual Cluster into the Kubernetes cluster your cli is pointed to.
    standalone            # Runs the helm install command to install a Neo4j Standalone Instance into the Kubernetes cluster your cli is pointed to.
    create-static-ips     # Using the GCP SDK creates static IPs for neo4j external access.
    elb-manifest-create   # Generates the GCP ELB Kubernetes Service Manifests with the static IPs that were generated from the create-static-ips command.
    apply-ext-manifests   # Applies the External Access Service Manifests into the Kubernetes cluster your cli is pointed to.
    remove-ext-manifests  # Removes the External Access Service Manifests from the Kubernetes cluster your cli is pointed to.
    helm-remove           # Removes the Helm installation from the Kubernetes cluster your cli is pointed to.
    remove-static-ips     # Using the GCP SDK deletes the static IPs that were created for neo4j external access.
    cleanup               # Removes/Deletes the Kubernetes manifests that were generated AND Deletes the GCP Static IPs that were created.
    exit                  # Exits the program.

Choice: ' CONTINUE
    case $CONTINUE in
      create-static-ips )
        create_static_ips
        ;;
      remove-static-ips )
        remove_static_ips
        ;;
      casual-cluster )
        casual_cluster
        ;;
      standalone )
        standalone
        ;;
      elb-manifest-create )
        elb_manifest_creation
        ;;
      apply-ext-manifests )
        apply_ext_manifests
        test_shit
        ;;
      remove-ext-manifests )
        remove_ext_manifests
        ;;
      cleanup )
        cleanup
        ;;
      test )
        test_shit
        ;;
      helm-remove )
        helm_remove
        ;;
      exit )
        clear
        echo ""
        echo "Thanks for playing!"
        echo ""
        sleep 1
        clear
        exit
    esac
  done
else
  case $1 in
    create-static-ips )
      create_static_ips
      ;;
    remove-static-ips )
      remove_static_ips
      ;;
    casual-cluster )
      casual_cluster
      ;;
    standalone )
      standalone
      ;;
    elb-manifest-create )
      elb_manifest_creation
      ;;
    apply-ext-manifests )
      apply_ext_manifests
      test_shit
      ;;
    remove-ext-manifests )
      remove_ext_manifests
      ;;
    cleanup )
      cleanup
      ;;
    test )
      test_shit
      ;;
    helm-remove )
      helm_remove
      ;;
    exit )
      clear
      echo ""
      echo "Thanks for playing!"
      echo ""
      exit
      ;;
  esac
fi
