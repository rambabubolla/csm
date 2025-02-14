#!/bin/bash
#
# MIT License
#
# (C) Copyright 2021-2024 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#

if [[ !  -v SYSCONFDIR ]]; then
    if [[ ! -v SYSTEM_NAME ]]; then
        echo >&2 "error: environment variable not set: SYSTEM_NAME"
        exit 1
    fi
    SYSCONFDIR="/var/www/ephemeral/prep/${SYSTEM_NAME}"
fi

if [[ ! -d "$SYSCONFDIR" ]]; then
    echo >&2 "warning: no such directory: SYSCONFDIR: $SYSCONFDIR"
fi

: "${SLS_INPUT_FILE:="${SYSCONFDIR}/sls_input_file.json"}"
if [[ ! -f "$SLS_INPUT_FILE" ]]; then
    echo >&2 "error: no such file: SLS_INPUT_FILE: $SLS_INPUT_FILE"
    exit 1
fi

set -exo pipefail

ROOTDIR="$(dirname "${BASH_SOURCE[0]}")"
source "${ROOTDIR}/lib/version.sh"
source "${ROOTDIR}/lib/install.sh"

: "${BUILDDIR:="${ROOTDIR}/build"}"
mkdir -p "$BUILDDIR"

[[ -f "${BUILDDIR}/customizations.yaml" ]] && rm -f "${BUILDDIR}/customizations.yaml"
kubectl get secrets -n loftsman site-init -o jsonpath='{.data.customizations\.yaml}' | base64 -d > "${BUILDDIR}/customizations.yaml"

# lower cpu request for tds systems (4 workers)
num_workers=$(kubectl get nodes | grep ncn-w | wc -l)
if [ $num_workers -le 4 ]; then
  dist=$(uname | awk '{print tolower($0)}')
  ${ROOTDIR}/shasta-cfg/utils/bin/${dist}/yq m -i --overwrite "${BUILDDIR}/customizations.yaml" /usr/share/doc/csm/upgrade/scripts/upgrade/tds_cpu_requests.yaml
  kubectl delete secret -n loftsman site-init
  kubectl create secret -n loftsman generic site-init --from-file="${BUILDDIR}/customizations.yaml"
fi

# Inject image signing keys into kyverno-policies customization
dist=$(uname | awk '{print tolower($0)}')
for key in ${ROOTDIR}/security/keys/oci/*.pub; do
    ${ROOTDIR}/shasta-cfg/utils/bin/${dist}/yq -P w -i "${BUILDDIR}/customizations.yaml" \
        "spec.kubernetes.services.kyverno-policy.checkImagePolicy.publicKeys[+]" -- "$(< "${key}")"
done
kubectl delete secret -n loftsman site-init
kubectl create secret -n loftsman generic site-init --from-file="${BUILDDIR}/customizations.yaml"

# Generate manifests with customizations
mkdir -p "${BUILDDIR}/manifests"
find "${ROOTDIR}/manifests" -name "*.yaml" | while read manifest; do
    manifestgen -i "$manifest" -c "${BUILDDIR}/customizations.yaml" -o "${BUILDDIR}/manifests/$(basename "$manifest")"
done

function deploy() {
    # XXX Loftsman may not be able to connect to $NEXUS_URL due to certificate
    # XXX trust issues, so use --charts-path instead of --charts-repo.
    loftsman ship --charts-path "${ROOTDIR}/helm" --manifest-path "$1"
}

# Deploy services critical for Nexus to run
deploy "${BUILDDIR}/manifests/storage.yaml"
deploy "${BUILDDIR}/manifests/platform.yaml"
deploy "${BUILDDIR}/manifests/keycloak-gatekeeper.yaml"

# Create secret with RPM signing keys
# For backward compatibility, also import hpe-signing-key.asc under the name "gpg-pubkey"
RPM_SIGNING_KEYS_OPT="--from-file gpg-pubkey=${ROOTDIR}/security/keys/rpm/hpe-signing-key.asc"
for key in ${ROOTDIR}/security/keys/rpm/*.asc; do
        RPM_SIGNING_KEYS_OPT="${RPM_SIGNING_KEYS_OPT} --from-file ${key}"
done
kubectl create secret generic hpe-signing-key -n services ${RPM_SIGNING_KEYS_OPT} --dry-run=client --save-config -o yaml | kubectl apply -f -

# Upload SLS Input file to S3
csi upload-sls-file --sls-file "$SLS_INPUT_FILE"
deploy "${BUILDDIR}/manifests/core-services.yaml"

# Update DNS settings on the pit server
"${ROOTDIR}/lib/wait-for-unbound.sh"
unbound_ip="$(kubectl get -n services service cray-dns-unbound-udp-nmn -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
sed -e "s/^\(NETCONFIG_DNS_STATIC_SERVERS\)=.*$/\1=\"${unbound_ip}\"/" -i /etc/sysconfig/network/config
netconfig update -f
systemctl stop dnsmasq
systemctl disable dnsmasq

# Deploy remaining system management applications
deploy "${BUILDDIR}/manifests/sysmgmt.yaml"

# Deploy Nexus
deploy "${BUILDDIR}/manifests/nexus.yaml"

# Deploy Vshasta specific services
function is_vshasta_node {
    # This is the best check for an image specifically booted to vshasta
    [[ -f /etc/google_system ]] && return 0

    # metal images can still be booted on GCP, so check if there are any disks vendored by Google
    # if not, we conclude that this is not GCP
    lsblk --noheadings -o vendor | grep -q Google
    return $?
}

if is_vshasta_node; then
    deploy "${BUILDDIR}/manifests/vshasta.yaml"
fi

set +x
cat >&2 <<EOF
+ CSM applications and services deployed
install.sh: OK
EOF
