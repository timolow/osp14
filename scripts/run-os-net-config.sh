#!/bin/bash
# The following environment variables may be set to substitute in a
# custom bridge or interface name.  Normally these are provided by the calling
# SoftwareConfig resource, but they may also be set manually for testing.
# $bridge_name : The bridge device name to apply
# $interface_name : The interface name to apply
#
# Also this token is replaced via a str_replace in the SoftwareConfig running
# the script - in future we may extend this to also work with a variable, e.g
# a deployment input via input_values
# $network_config : the json serialized os-net-config config to apply
#
set -eux

function get_metadata_ip() {

  local METADATA_IP

  # Look for a variety of Heat transports
  # FIXME: Heat should provide a way to obtain this in a single place
  for URL in os-collect-config.cfn.metadata_url os-collect-config.heat.auth_url os-collect-config.request.metadata_url os-collect-config.zaqar.auth_url; do
    METADATA_IP=$(os-apply-config --key $URL --key-default '' --type raw 2>/dev/null | sed -e 's|http.*://\[\?\([^]]*\)]\?:.*|\1|')
    [ -n "$METADATA_IP" ] && break
  done

  echo $METADATA_IP

}

function is_local_ip() {
  local IP_TO_CHECK=$1
  if ip -o a | grep "inet6\? $IP_TO_CHECK/" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

function ping_metadata_ip() {
  local METADATA_IP=$(get_metadata_ip)

  if [ -n "$METADATA_IP" ] && ! is_local_ip $METADATA_IP; then

    echo -n "Trying to ping metadata IP ${METADATA_IP}..."

    _IP="$(getent hosts $METADATA_IP | awk '{ print $1 }')"
    _ping=ping
    if [[ "$_IP" =~ ":" ]] ; then
        _ping=ping6
    fi

    local COUNT=0
    until $_ping -c 1 $METADATA_IP &> /dev/null; do
      COUNT=$(( $COUNT + 1 ))
      if [ $COUNT -eq 10 ]; then
        echo "FAILURE"
        echo "$METADATA_IP is not pingable." >&2
        exit 1
      fi
    done
    echo "SUCCESS"

  else
    echo "No metadata IP found. Skipping."
  fi
}

function configure_safe_defaults() {

[[ $? == 0 ]] && return 0

cat > /etc/os-net-config/dhcp_all_interfaces.yaml <<EOF_CAT
# This file is an autogenerated safe defaults file for os-net-config
# which runs DHCP on all discovered interfaces to ensure connectivity
# back to the undercloud for updates
network_config:
EOF_CAT

    for iface in $(ls /sys/class/net | grep -v -e ^lo$ -e ^vnet$); do
        local mac_addr_type="$(cat /sys/class/net/${iface}/addr_assign_type)"
        if [ "$mac_addr_type" != "0" ]; then
            echo "Device has generated MAC, skipping."
        else
            HAS_LINK="$(cat /sys/class/net/${iface}/carrier || echo 0)"

            TRIES=10
            while [ "$HAS_LINK" == "0" -a $TRIES -gt 0 ]; do
                # Need to set the link up on each iteration
                ip link set dev $iface up &>/dev/null
                HAS_LINK="$(cat /sys/class/net/${iface}/carrier || echo 0)"
                if [ "$HAS_LINK" == "1" ]; then
                    break
                else
                    sleep 1
                fi
                TRIES=$(( TRIES - 1 ))
            done
            if [ "$HAS_LINK" == "1" ] ; then
cat >> /etc/os-net-config/dhcp_all_interfaces.yaml <<EOF_CAT
  -
    type: interface
    name: $iface
    use_dhcp: true
EOF_CAT
            fi
        fi
    done
    set +e
    os-net-config -c /etc/os-net-config/dhcp_all_interfaces.yaml -v --detailed-exit-codes --cleanup
    RETVAL=$?
    set -e
    if [[ $RETVAL == 2 ]]; then
        ping_metadata_ip
    elif [[ $RETVAL != 0 ]]; then
        echo "ERROR: configuration of safe defaults failed."
    fi
}

if [ -n '$network_config' ]; then
    if [ -z "${disable_configure_safe_defaults:-}" ]; then
        trap configure_safe_defaults EXIT
    fi

    mkdir -p /etc/os-net-config
    # Note these variables come from the calling heat SoftwareConfig
    echo '$network_config' > /etc/os-net-config/config.json

    if [ "$(type -t network_config_hook)" = "function" ]; then
        network_config_hook
    fi

    sed -i "s/bridge_name/${bridge_name:-''}/" /etc/os-net-config/config.json
    sed -i "s/interface_name/${interface_name:-''}/" /etc/os-net-config/config.json

    set +e
    os-net-config -c /etc/os-net-config/config.json -v --detailed-exit-codes
    RETVAL=$?
    set -e

    if [[ $RETVAL == 2 ]]; then
        ping_metadata_ip

        #NOTE: dprince this udev rule can apparently leak DHCP processes?
        # https://bugs.launchpad.net/tripleo/+bug/1538259
        # until we discover the root cause we can simply disable the
        # rule because networking has already been configured at this point
        if [ -f /etc/udev/rules.d/99-dhcp-all-interfaces.rules ]; then
            rm /etc/udev/rules.d/99-dhcp-all-interfaces.rules
        fi

    elif [[ $RETVAL != 0 ]]; then
        echo "ERROR: os-net-config configuration failed." >&2
        exit 1
    fi

    # Remove files used by os-apply-config for old style configs
    if [ -f /usr/libexec/os-apply-config/templates/etc/os-net-config/config.json ]; then
        rm /usr/libexec/os-apply-config/templates/etc/os-net-config/config.json
    fi
    if [ -f /usr/libexec/os-apply-config/templates/etc/os-net-config/element_config.json ]; then
        rm /usr/libexec/os-apply-config/templates/etc/os-net-config/element_config.json
    fi
fi