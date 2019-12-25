#!/bin/bash

# A heat-config-script which runs yum update during a stack-update.
# Inputs:
#   deploy_action - yum will only be run if this is UPDATE
#   update_identifier - yum will only run for previously unused values of update_identifier
#   command - yum sub-command to run, defaults to "update"
#   command_arguments - yum command arguments, defaults to ""

echo "Started yum_update.sh on server $deploy_server_id at `date`"
echo -n "false" > $heat_outputs_path.update_managed_packages

if [[ -z "$update_identifier" ]]; then
    echo "Not running due to unset update_identifier"
    exit 0
fi

timestamp_dir=/var/lib/overcloud-yum-update
mkdir -p $timestamp_dir

# sanitise to remove unusual characters
update_identifier=${update_identifier//[^a-zA-Z0-9-_]/}

# seconds to wait for this node to rejoin the cluster after update
cluster_start_timeout=600
galera_sync_timeout=1800
cluster_settle_timeout=1800

timestamp_file="$timestamp_dir/$update_identifier"
if [[ -a "$timestamp_file" ]]; then
    echo "Not running for already-run timestamp \"$update_identifier\""
    exit 0
fi
touch "$timestamp_file"

# install openstack-nova-migration on computes prior to checking for updates
if hiera -c /etc/puppet/hiera.yaml service_names | grep -q nova_compute; then
    echo "Checking openstack-nova-migration is installed"
    if ! yum -q list installed openstack-nova-migration > /dev/null 2>&1; then
        echo "Installing openstack-nova-migration"
        yum -q -y install openstack-nova-migration
    fi
fi

command_arguments=${command_arguments:-}

# Always ensure yum has full cache
yum makecache || echo "Yum makecache failed. This can cause failure later on."

# yum check-update exits 100 if updates are available
set +e
check_update=$(yum check-update 2>&1)
check_update_exit=$?
set -e

if [[ "$check_update_exit" == "1" ]]; then
    echo "Failed to check for package updates"
    echo "$check_update"
    exit 1
elif [[ "$check_update_exit" != "100" ]]; then
    echo "No packages require updating"
    exit 0
fi

pacemaker_status=""
if hiera -c /etc/puppet/hiera.yaml service_names | grep -q pacemaker; then
    pacemaker_status=$(systemctl is-active pacemaker)
fi

# TODO: FIXME: remove this in Pike.
# Hack around mod_ssl update and puppet https://bugs.launchpad.net/tripleo/+bug/1682448
touch /etc/httpd/conf.d/ssl.conf

# Fix the redis/rabbit resource start/stop timeouts. See https://bugs.launchpad.net/tripleo/+bug/1633455
# and https://bugs.launchpad.net/tripleo/+bug/1634851
if [[ "$pacemaker_status" == "active" && \
      -n $(is_bootstrap_node) ]] ; then
    if pcs resource show rabbitmq | grep -E "start.*timeout=100"; then
        pcs resource update rabbitmq op start timeout=200s
    fi
    if pcs resource show rabbitmq | grep -E "stop.*timeout=90"; then
        pcs resource update rabbitmq op stop timeout=200s
    fi
    if pcs resource show redis | grep -E "start.*timeout=120"; then
        pcs resource update redis op start timeout=200s
    fi
    if pcs resource show redis | grep -E "stop.*timeout=120"; then
        pcs resource update redis op stop timeout=200s
    fi
fi

# Resolve any RPM dependency issues before attempting the update
yum_pre_update

if [[ "$pacemaker_status" == "active" ]] ; then
    echo "Pacemaker running, stopping cluster node and doing full package update"
    node_count=$(pcs status xml | grep -o "<nodes_configured.*/>" | grep -o 'number="[0-9]*"' | grep -o "[0-9]*")
    if [[ "$node_count" == "1" ]] ; then
        echo "Active node count is 1, stopping node with --force"
        pcs cluster stop --force
    else
        pcs cluster stop
    fi
    update_network
else
    update_network
    echo "Upgrading openstack-puppet-modules and its dependencies"
    check_for_yum_lock
    yum -q -y update openstack-puppet-modules
    yum deplist openstack-puppet-modules | awk '/dependency/{print $2}' | xargs yum -q -y update
    echo "Upgrading other packages is handled by config management tooling"
    echo -n "true" > $heat_outputs_path.update_managed_packages
    exit 0
fi

command=${command:-update}
full_command="yum -q -y $command $command_arguments"

echo "Running: $full_command"
check_for_yum_lock
result=$($full_command)
return_code=$?
echo "$result"
echo "yum return code: $return_code"

if [[ "$pacemaker_status" == "active" ]] ; then
    echo "Starting cluster node"
    pcs cluster start

    hostname=$(hostname -s)
    tstart=$(date +%s)
    while [[ "$(pcs status | grep "^Online" | grep -F -o $hostname)" == "" ]]; do
        sleep 5
        tnow=$(date +%s)
        if (( tnow-tstart > cluster_start_timeout )) ; then
            echo "ERROR $hostname failed to join cluster in $cluster_start_timeout seconds"
            pcs status
            exit 1
        fi
    done

    tstart=$(date +%s)
    while ! clustercheck; do
        sleep 5
        tnow=$(date +%s)
        if (( tnow-tstart > galera_sync_timeout )) ; then
            echo "ERROR galera sync timed out"
            exit 1
        fi
    done

    echo "Waiting for pacemaker cluster to settle"
    if ! timeout -k 10 $cluster_settle_timeout crm_resource --wait; then
        echo "ERROR timed out while waiting for the cluster to settle"
        exit 1
    fi

    pcs status
fi

# We didn't complete the M->N upgrades correctly with a
# `nova-manage db online_data_migrations` command before, which might result in
# a performance impairment. So, as a stop-gap-solution we run it here on the
# first controller node, which is a noop if there is nothing to do.
if hiera -c /etc/puppet/hiera.yaml service_names | grep -q nova_api && \
  [[ -n $(is_bootstrap_node) ]] ; then
    /usr/bin/nova-manage db online_data_migrations
fi

echo "Finished yum_update.sh on server $deploy_server_id at `date`"

exit $return_code
