#!/bin/sh
########################################################################
# This script will monitor health of neighbor NAT instance and in case
# of failure it will move EIP and change routing table
#
# Author: Alexey Kamenskiy <alexey.kamenskiy@chinanetcloud.com>
# Copyright 2018 (c) China Net Cloud
########################################################################

# IAM policy required for getting info about another instance, move EIP,
# updating route tables, stopping other instance to prevent split-brain.
# Additionally you can split this policy and restrict by resource as
# needed
#
# {
#  "Statement": [
#    {
#      "Action": [
#        "ec2:DescribeInstances",
#        "ec2:StopInstances",
#        "ec2:DescribeRouteTables",
#        "ec2:ReplaceRoute",
#        "ec2:AssociateAddress",
#        "ec2:DescribeAddresses",
#        "ec2:DescribeNetworkInterfaces"
#      ],
#      "Effect": "Allow",
#      "Resource": "*"
#    }
#  ]
# }



## INPUT VARIABLES
# Neighbor NAT instance ID to monitor
NEIGHBOR_ID="i-XXX"
# Routing table ID that will be modified upon failover. Space separated string of IDs
RT_IDS="rtb-XXX rtb-YYY"
# EIP ID to reassign upon failover (eipalloc-XXXXXX)
EIP_ID="eipalloc-XXX"
# Command to execute after the failover
# this is executed as `/bin/sh -c "${POST_FAILOVER_CMD}"`, so ensure it is written appropriately
# Also note that you should respect stdout and stderr for that command/script
POST_FAILOVER_CMD=""

## HEALTH CHECK VARIABLES
# How many times to ping
PING_COUNT=5

# Easy error exit function
err() {
    echo "$@" 1>&2
    exit 1
};

# Get default environment variables
. /etc/profile.d/aws-apitools-common.sh

# Get our own ID
if ! INSTANCE_ID=$(curl --silent http://169.254.169.254/latest/meta-data/instance-id 2>&1); then
    err ${INSTANCE_ID}
fi

# Get the other NAT instance's IP
if ! output=$(aws ec2 describe-instances --instance-ids ${NEIGHBOR_ID} 2>&1); then
    err ${output}
else
    if ! NEIGHBOR_IP=$(echo "$output" | jq -r -e ".Reservations[0].Instances[0].PrivateIpAddress" 2>&1); then
        err "Failed to get neighbor IP by instance ID"
    fi
fi

# Check where ip AND routing table pointed at:
#     if ourselves then we do nothing and just exit with 0
#     if some unknown instance OR ip and default route point to different instances then fail
#     if our neighbor then run health check against neighbor
# If health check passes then do nothing and exit with 0
# if health check fails then do following sequence:
#     0. Write to stderr message that we start failure procedure
#     1. Call API to stop neighbor instance
#     2. Update default route to point to ourselves
#     3. Assign EIP to ourselves
#     4. Run script for post failover action
#     5. If all above succeeds exit with 0

# Get the instance ID associated with EIP
if ! output=$(aws ec2 describe-addresses --allocation-ids ${EIP_ID} 2>&1); then
    err ${output}
else
    if ! EIP_INSTANCE_ID=$(echo "${output}" | jq -r -e ".Addresses[0].InstanceId"); then
        err "EIP does not seem to be associated with any instance"
    fi
fi

# If EIP points to this instance, then we should just exit
if [ "${EIP_INSTANCE_ID}" == "${INSTANCE_ID}" ]; then
    exit 0
fi

# If EIP does not point to neighbor, then should exit with error
if [ "${EIP_INSTANCE_ID}" != "${NEIGHBOR_ID}" ]; then
    err "Configured EIP does not point to any of configured NAT instances. That's a no-go"
fi

# Get the default route
if ! output=$(aws ec2 describe-route-tables --route-table-ids ${RT_IDS} 2>&1); then
    err ${output}
else
    if ! rt_dst_enis=$(echo "${output}" | jq -e -r '.RouteTables[].Routes[] | select(.DestinationCidrBlock == "0.0.0.0/0") | .NetworkInterfaceId'); then
        err "One or more routing tables do not belong on this list! Only routing tables for private subnets (pointing to ENI for default route) are allowed here"
    else
        # From list of ENIs get list of instance IDs
        if ! output=$(aws ec2 describe-network-interfaces --network-interface-ids ${rt_dst_enis} 2>&1); then
            err ${output}
        else
            if ! tmp_instance_ids=$(echo "${output}" | jq -e -r '.NetworkInterfaces[].Attachment.InstanceId'); then
                err "One or more ENIs in managed routing tables does not exist creating blachole for default route"
            else
                # Uniq all instance IDS, because result should be just one of them
                RT_INSTANCE_ID=$(echo "${tmp_instance_ids}" | uniq)
            fi
        fi
    fi
fi

# If EIP does not point to neighbor, then we should exit with error
if [ "${RT_INSTANCE_ID}" != "${NEIGHBOR_ID}" ]; then
    err "One or more configured routing tables does not point to neighbor NAT instance"
fi

# Do ping health-check of neighbor NAT instance
if output=$(ping ${NEIGHBOR_IP} -c ${PING_COUNT} 2>&1); then
    # Success, so can exit safely
    exit 0
fi

#############################################################################
# If we got here, that means health-check failed, so we need to do failover #
#############################################################################

# 0. Write to stderr message that we start failure procedure
echo "ATTENTION!!! HEALTH CHECK FAILED FOR ${NEIGHBOR_ID}. STARTING FAILOVER PROCESS" 1>&2

# Write the stdout
echo "============================================="
echo "Date: " $(date)
echo "============================================="

# 1. Call API to stop neighbor instance, it is okay to fail this one, we just do it as a precaution
echo "STOPPING ${NEIGHBOR_ID}. STARTING FAILOVER PROCESS"
if ! output=$(aws ec2 stop-instances --instance-ids ${NEIGHBOR_ID} 2>&1); then
    echo "API CALL TO STOP INSTANCE HAS FAILED"
fi

# 2. Update default routes in all tables to point to ourselves, this is critical,
# if we failed to replace route we should panic, but we should do out best effort here
for RT_ID in ${RT_IDS}; do
    echo "UPDATING ROUTING TABLE ${RT_ID} WITH DEFAULT ROUTE 0.0.0.0/0 TO ${INSTANCE_ID}"
    if ! output=$(aws ec2 replace-route --route-table-id ${RT_ID} --destination-cidr-block "0.0.0.0/0" --instance-id ${INSTANCE_ID} 2>&1); then
        echo "FAILED TO UPDATE ROUTING TABLE ${RT_ID}"
    fi
done

# 3. Assign EIP to ourselves
echo "MOVING EIP ${EIP_ID} FROM ${NEIGHBOR_ID} TO ${INSTANCE_ID}"
if ! output=$(aws ec2 associate-address --allocation-id ${EIP_ID} --instance-id ${INSTANCE_ID} 2>&1); then
    echo "FAILED TO MOVE EIP"
    # If we failed to move EIP, that is hardcore failure and we exit with error code here
    err "FAILED TO MOVE EIP"
fi

# 4. Execute post failover action if provided
if [ ! -z "${POST_FAILOVER_CMD}" ]; then
    echo "EXECUTING POST FAILOVER ACTION '${POST_FAILOVER_CMD}'"
    /bin/sh -c "${POST_FAILOVER_CMD}"
fi

# 5. If all above succeeds exit with 0
exit 0
