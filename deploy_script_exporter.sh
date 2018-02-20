#!/bin/bash

set -e
set -u
set -x

# These variables should not change much
USAGE="Usage: $0 <project> <keyname>"
PROJECT=${1:?Please provide project name: $USAGE}
KEYNAME=${2:?Please provide an authentication key name: $USAGE}
SCP_FILES="apply_tc_rules.sh Dockerfile ndt_e2e.sh script_exporter.yml"
IMAGE_TAG="m-lab/prometheus-script-exporter"
GCE_ZONE="us-central1-a"
GCE_NAME="script-exporter"
GCE_IP_NAME="script-exporter-public-ip"
GCE_IMG_PROJECT="coreos-cloud"
GCE_IMG_FAMILY="coreos-stable"

# The script_exporter targets for each project only include the nodes specific
# to that project. That is, the mlab-sandbox project will only have targets for
# testing nodes, which is a small number. And the mlab-staging project will
# only have targets for mlab4 nodes, which is more nodes than the mlab-sandbox
# project. The mlab-oti project will have significantly more targets, all
# mlab[1-3]s, than the other projects. Because of this, the demands on CPU and
# memory will vary. This case statement allows us to set per project GCE
# instance machine types to account for expected load.
case $PROJECT in
  mlab-oti)
    MACHINE_TYPE="n1-standard-8"
    ;;
  mlab-staging)
    MACHINE_TYPE="n1-standard-2"
    ;;
  *)
    MACHINE_TYPE="n1-standard-1"
    ;;
esac

# Add gcloud to PATH.
source "${HOME}/google-cloud-sdk/path.bash.inc"

# Add m-lab/travis help lib
source "$TRAVIS_BUILD_DIR/travis/gcloudlib.sh"

# Set the project and zone for all future gcloud commands.
gcloud config set project $PROJECT
gcloud config set compute/zone $GCE_ZONE

# Authenticate the service account using KEYNAME.
activate_service_account "${KEYNAME}"

# Make sure that the files we want to copy actually exist.
for scp_file in ${SCP_FILES}; do
  if [[ ! -e "${TRAVIS_BUILD_DIR}/${scp_file}" ]]; then
    echo "Missing required file/dir: ${TRAVIS_BUILD_DIR}/${scp_file}!"
    exit 1
  fi
done

# Delete the existing GCE instance, if it exists. gcloud has an exit status of 0
# whether any instances are found or not. When no instances are found, a short
# message is echoed to stderr. When an instance is found a summary is echoed to
# stdout. If $EXISTING_INSTANCE is not null then we infer that the instance
# already exists.
EXISTING_INSTANCE=$(gcloud compute instances list --filter "name=${GCE_NAME}")
if [[ -n "${EXISTING_INSTANCE}" ]]; then
  gcloud compute instances delete $GCE_NAME --quiet
fi

# Create the new GCE instance. NOTE: $GCE_IP_NAME *must* refer to an existing
# static external IP address for the project.
gcloud compute instances create $GCE_NAME --address $GCE_IP_NAME \
  --image-project $GCE_IMG_PROJECT --image-family $GCE_IMG_FAMILY \
  --tags script-exporter --metadata-from-file user-data=cloud-config.yml \
  --machine-type $MACHINE_TYPE

# Give the GCE instance another 30s to fully become available. From time to time
# the Travis-CI build fails because it can't connect via SSH.
sleep 30

# Copy required snmp_exporter files to the GCE instance.
gcloud compute scp $SCP_FILES $GCE_NAME:~

# Build the snmp_exporter Docker container.
gcloud compute ssh $GCE_NAME --command "docker build -t ${IMAGE_TAG} ."

# Start a new container based on the new/updated image.
gcloud compute ssh $GCE_NAME --command "docker run --detach --restart always --publish 9172:9172 --cap-add NET_ADMIN ${IMAGE_TAG}"

# Run Prometheus node_exporter in a container so we can gather VM metrics.
gcloud compute ssh $GCE_NAME --command "docker run --detach --restart always --publish 9100:9100 --volume /proc:/host/proc --volume /sys:/host/sys prom/node-exporter --path.procfs /host/proc --path.sysfs /host/sys --no-collector.arp --no-collector.bcache --no-collector.conntrack --no-collector.edac --no-collector.entropy --no-collector.filefd --no-collector.hwmon --no-collector.infiniband --no-collector.ipvs --no-collector.mdadm --no-collector.netstat --no-collector.sockstat --no-collector.time --no-collector.timex --no-collector.uname --no-collector.vmstat --no-collector.wifi --no-collector.xfs --no-collector.zfs"
