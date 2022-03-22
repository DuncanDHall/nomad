#!/bin/zsh -e

# One time setup of server(s) to make a nomad cluster.


MYDIR=${0:a:h}
MYSELF=$MYDIR/setup.sh

# where supporting scripts live and will get pulled from
REPO=https://gitlab.com/internetarchive/nomad/-/raw/master


function usage() {
  echo "
----------------------------------------------------------------------------------------------------
Usage: $MYSELF  [TLS_CRT file]  [TLS_KEY file]  <node 1>  <node 2>  ..

----------------------------------------------------------------------------------------------------
[TLS_CRT file] - wildcard domain cert file location, PEM format.  eg: .../archive.org-cert.pem
[TLS_KEY file] - wildcard domain  key file location, PEM format.  eg: .../archive.org-key.pem
    File locations can be local to each VM
    or in \`rsync\` format where you prepend '[SERVER]:' in the filename

Run this script on a mac/linux laptop or VM where you can ssh in to all of your nodes.

If invoking cmd-line has env var:
  NFSHOME=1                     -- then we'll setup /home/ r/o and r/w mounts
  NFS_PV=[IP ADDRESS:MOUNT_DIR] -- then we'll setup each VM with /pv mounting your NFS server for
                                   Persistent Volumes.  Example value: 1.1.1.1:/mnt/exports

To simplify, we'll reuse TLS certs, setting up ACL and TLS for nomad.

----------------------------------------------------------------------------------------------------
Assumes you are creating cluster with debian/ubuntu VMs/baremetals,
that you have ssh and sudo access to.

Overview:
  Installs nomad server and client on all nodes, securely talking together & electing a leader
  Installs consul server and client on all nodes
  Installs load balancer 'fabio' on all nodes
     (in case you want to use multiple IP addresses for deployments in case one LB/node is out)

----------------------------------------------------------------------------------------------------
NOTE: if setup 3 nodes (h0, h1 & h2) on day 1; and want to add 2 more (h3 & h4) later,
you should manually change 2 lines in \`setup-env-vars()\` in script -- look for INITIAL_CLUSTER_SIZE

"
  exit 1
}


function main() {
  if [ "$#" -gt 2 ]; then
    # This is where the script starts
    setup-env-vars "$@"
    set -x

    # Setup certs & get consul up & running *first* -- so can use consul for nomad bootstraping.
    # Run "setup-consul-and-certs" across all VMs.
    # https://learn.hashicorp.com/tutorials/nomad/clustering#use-consul-to-automatically-cluster-nodes
    for NODE in ${NODES?}; do
      # copy ourself / this script & env file over to the node first, then run script
      cat /tmp/setup.env | ssh $NODE 'tee /tmp/setup.env >/dev/null'
      cat ${MYSELF}      | ssh $NODE 'tee /tmp/setup.sh  >/dev/null  &&  chmod +x /tmp/setup.sh'
      ssh $NODE  /tmp/setup.sh  setup-consul-and-certs
    done


    # Now get nomad configured and up - run "setup-nomad" on all VMs.
    for NODE in ${NODES?}; do
      ssh $NODE  /tmp/setup.sh  setup-nomad
    done

    finish

  elif [ "$1" = "setup-consul-and-certs" ]; then
    setup-consul-and-certs

  elif [ "$1" = "setup-nomad" ]; then
    setup-nomad

  else
    usage "$@"
  fi
}


function setup-env-vars() {
  # sets up environment variables into a tmp file and then sources it

  # avoid any potentially previously set external environment vars from CLI poisoning..
  unset   NOMAD_TOKEN
  unset   NOMAD_ADDR


  TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
  TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created
  shift
  shift

  # number of args now left from the command line are all the hostnames to setup
  typeset -a $NODES # array type env variable
  NODES=( "$@" )
  CLUSTER_SIZE=$#


  # This is normally 0, but if you later add nodes to an existing cluster, set this to
  # the number of nodes in the existing cluster.
  # Also manually set FIRST here to hostname of your existing cluster first VM.
  local INITIAL_CLUSTER_SIZE=0
  FIRST=$NODES[1]


  FIRST_FQDN=$(ssh $FIRST hostname -f)

  # write all our needed environment variables to a file
  (
    # logical constants
    echo export CONSUL_ADDR="http://localhost:8500"
    echo export  FABIO_ADDR="http://localhost:9998"

    # Let's put LB/fabio and consul on all servers
    echo export LB_COUNT=${CLUSTER_SIZE?}
    echo export CONSUL_COUNT=${CLUSTER_SIZE?}

    echo export NOMAD_ADDR="https://${FIRST_FQDN?}:4646"

    echo export FIRST=$FIRST
    echo export FIRST_FQDN=$FIRST_FQDN
    echo export TLS_CRT=$TLS_CRT
    echo export TLS_KEY=$TLS_KEY
    echo export NFSHOME=$NFSHOME
    echo export NFS_PV="$NFS_PV"
    echo export CLUSTER_SIZE=$CLUSTER_SIZE

    # this is normally 0, but if you later add nodes to an existing cluster, set this to
    # the number of nodes in the existing cluster.
    echo export INITIAL_CLUSTER_SIZE=$INITIAL_CLUSTER_SIZE

    # For each NODE to install on, set the COUNT or hostnumber from the order from the command line.
    COUNT=${INITIAL_CLUSTER_SIZE?}
    for NODE in ${NODES?}; do
      echo export COUNT_$COUNT=$NODE
      let "COUNT=$COUNT+1"
    done
  ) |sort >| /tmp/setup.env

  source /tmp/setup.env
}


function load-env-vars() {
  # avoid any potentially previously set external environment vars from CLI poisoning..
  unset   NOMAD_TOKEN
  unset   NOMAD_ADDR

  # loads environment variables that `setup-env-vars` previously setup
  source /tmp/setup.env

  # Now figure out what our COUNT number is for the host we are running on now.
  # Try short and FQDN hostnames since not sure what user ran on cmd-line.
  for HO in  $(hostname -s)  $(hostname); do
    export COUNT=$(env |egrep '^COUNT_'| fgrep "$HO" |cut -f1 -d= |cut -f2 -d_)
    [ -z "$COUNT" ]  ||  break
  done

  set -x
}


function setup-consul-and-certs() {
  load-env-vars

  cd /tmp

  setup-misc
  setup-PV
  setup-certs
  setup-consul
  setup-404-page
}


function setup-consul() {
  # sets up consul
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
  sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
  sudo apt-get -yqq update

  # install binaries and service files
  #   eg: /usr/bin/consul  /etc/consul.d/consul.hcl  /usr/lib/systemd/system/consul.service
  sudo apt-get -yqq install  consul

  # start up uncustomized version of consul
  sudo systemctl daemon-reload
  sudo systemctl enable  consul

  # find daemon config files from listing apt pkg contents ( eg: /etc/nomad.d/nomad.hcl )
  CONSUL_HCL=$(dpkg -L consul 2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')

  # restore original config (if reran)
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL

  # stash copies of original config
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig


  # setup the fields 'encrypt' etc. as per your cluster.
  if [ ${COUNT?} -eq 0 ]; then
    # starting cluster - how exciting!  mint some tokens
    TOK_C=$(consul keygen |tr -d ^)
  else
    # get the encrypt value from the first node's configured consul /etc/ file
    TOK_C=$(ssh ${FIRST?} "egrep '^encrypt\s*=' ${CONSUL_HCL?}" |cut -f2- -d= |tr -d '\t "')
  fi

  # get IP address of FIRST
  local FIRSTIP=$(host ${FIRST?} | perl -ane 'print $F[3] if $F[2] eq "address"' |head -1)

  echo '
server = true
advertise_addr = "{{ GetInterfaceIP \"eth0\" }}"
node_name = "'$(hostname -s)'"
bootstrap_expect = '${CONSUL_COUNT?}'
encrypt = "'${TOK_C?}'"
retry_join = ["'${FIRSTIP?}'"]
' | sudo tee -a  $CONSUL_HCL

  # restart and give a few seconds to ensure server responds
  sudo systemctl restart consul  &&  sleep 10


  # avoid a decrypt bug (consul servers speak encrypted to each other over https)
  sudo rm -fv /opt/consul/serf/local.keyring
  # restart and give a few seconds to ensure server responds
  sudo systemctl restart  consul  &&  sleep 10


  set +x

  echo "================================================================================"
  ( set -x; consul members )
  echo "================================================================================"
}


function setup-nomad {
  # sets up nomad
  load-env-vars

  sudo apt-get -yqq install  nomad

  # find daemon config files from listing apt pkg contents ( eg: /etc/nomad.d/nomad.hcl )
  NOMAD_HCL=$( dpkg -L nomad  2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')


  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig

  sudo systemctl daemon-reload
  sudo systemctl enable  nomad


  # now that this user and group exist, lock certs dir down
  sudo chown -R nomad.nomad /opt/nomad/tls


  # setup the fields 'encrypt' etc. as per your cluster.
  [ ${COUNT?} -eq 0 ]  &&  export TOK_N=$(nomad operator keygen |tr -d ^ |cat)
  # get the encrypt value from the first node's configured nomad /etc/ file
  [ ${COUNT?} -ge 1 ]  &&  export TOK_N=$(ssh ${FIRST?} "egrep  'encrypt\s*=' ${NOMAD_HCL?}"  |cut -f2- -d= |tr -d '\t "' |cat)

  # We'll put a loadbalancer on all cluster nodes (unless installer wants otherwise)
  export KIND=""
  if [ ${COUNT?} -lt ${LB_COUNT?} ]; then
    if [ "$KIND" = "" ]; then
      export KIND="lb"
    else
      export KIND="$KIND,lb"
    fi
  fi


  export HOME_NFS=/tmp/home
  [ $NFSHOME ]  &&  export HOME_NFS=/home


  getr etc/nomad.hcl
  # interpolate  /tmp/nomad.hcl  to  $NOMAD_HCL
  ( echo "cat <<EOF"; cat /tmp/nomad.hcl; echo EOF ) | sh | sudo tee $NOMAD_HCL
  rm /tmp/nomad.hcl


  # setup only 1st server to go into bootstrap mode (with itself)
  [ ${COUNT?} -ge 1 ] && sudo sed -i -e 's^bootstrap_expect =.*$^^' $NOMAD_HCL


  ) |sudo tee -a $NOMAD_HCL


  # restart and give a few seconds to ensure server responds
  sudo systemctl restart nomad  &&  sleep 10

  # NOTE: if you see failures join-ing and messages like:
  #   "No installed keys could decrypt the message"
  # try either (depending on nomad or consul) inspecting all nodes' contents of file) and:
  # sudo rm /opt/nomad/data/server/serf.keyring
  # sudo systemctl restart  nomad
  set +x

  nomad-addr-and-token
  echo "================================================================================"
  ( set -x; nomad server members )
  echo "================================================================================"
  ( set -x; nomad node status )
  echo "================================================================================"


  # install fabio/loadbalancer across all nodes
  nomad run ${REPO?}/etc/fabio.hcl
}


function nomad-addr-and-token() {
  # sets NOMAD_ADDR and NOMAD_TOKEN
  CONF=$HOME/.config/nomad
  if [ "$COUNT" = "0" ]; then
    # First VM -- bootstrap the entire nomad cluster
    # If you already have a .config/nomad file -- copy it to a `.prev` file.
    [ -e $CONF ]  &&  mv $CONF $CONF.prev
    # we only get one shot at bootstrapping the ACL info access to nomad -- so save entire response
    # to a separate file (that we can extract needed TOKEN from)
    local NOMACL=$HOME/.config/nomad.${FIRST?}
    mkdir -p $(dirname $NOMACL)
    chmod 600 $NOMACL $CONF 2>/dev/null |cat
    nomad acl bootstrap |tee $NOMACL
    # NOTE: can run `nomad acl token self` post-facto if needed...

    # extract TOKEN from $NOMACL; set it to NOMAD_TOKEN; place the 2 nomad access env vars into $CONF
    echo "
export NOMAD_ADDR=$NOMAD_ADDR
export NOMAD_TOKEN="$(fgrep 'Secret ID' $NOMACL |cut -f2- -d= |tr -d ' ') |tee $CONF
    chmod 400 $NOMACL $CONF
  fi
  source $CONF
}



function setup-misc() {
  # sets up docker (if needed) and a few other misc. things
  sudo apt-get -yqq install  wget

  # install docker if not already present
  getr install-docker-ce.sh
  /tmp/install-docker-ce.sh

  setup-ctop

  if [ -e /etc/ferm ]; then
    # archive.org uses `ferm` for port firewalling.
    # Open the minimum number of HTTP/TCP/UDP ports we need to run.
    getr ports-unblock.sh
    /tmp/ports-unblock.sh
    sudo service docker restart  ||  echo 'no docker yet'
  fi


  # This gets us DNS resolving on archive.org VMs, at the VM level (not inside containers)-8
  # for hostnames like:
  #   services-clusters.service.consul
  if [ -e /etc/dnsmasq.d/ ]; then
    echo "server=/consul/127.0.0.1#8600" |sudo tee /etc/dnsmasq.d/nomad
    # restart and give a few seconds to ensure server responds
    sudo systemctl restart dnsmasq
    sleep 2
  fi

  FI=/lib/systemd/system/systemd-networkd.socket
  if [ -e $FI ]; then
    # workaround focal-era bug after ~70 deploys (and thus 70 "veth" interfaces)
    # https://www.mail-archive.com/ubuntu-bugs@lists.ubuntu.com/msg5888501.html
    sudo sed -i -e 's^ReceiveBuffer=.*$^ReceiveBuffer=256M^' $FI
  fi


  # Need more (3GB) dirty byte limit for `docker pull` untar phase, else they can fail repeatedly.
  # IA Samuel only recomends on hosts w/ heavy fs metadata behavior + kernel 5.4 or newer for now.
  [ -e /proc/sys/vm/dirty_bytes ]  &&  echo 3221225472 |sudo tee /proc/sys/vm/dirty_bytes
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  local DOMAIN=$(echo ${FIRST_FQDN?} |cut -f2- -d.)
  local CRT=/etc/fabio/ssl/${DOMAIN?}-cert.pem
  local KEY=/etc/fabio/ssl/${DOMAIN?}-key.pem

  sudo mkdir -p         /etc/fabio/ssl/
  sudo chown root:root  /etc/fabio/ssl/
  wget -qO- ${REPO?}/etc/fabio.properties |sudo tee /etc/fabio/fabio.properties

  sudo rsync -Pav ${TLS_CRT?} ${CRT?}
  sudo rsync -Pav ${TLS_KEY?} ${KEY?}

  sudo chown root:root ${CRT} ${KEY}
  sudo chmod 444 ${CRT}
  sudo chmod 400 ${KEY}


  # setup nomad w/ same https certs so they can talk to each other, and we can talk to them securely
  sudo mkdir -m 500 -p      /opt/nomad/tls
  sudo cp $CRT              /opt/nomad/tls/tls.crt
  sudo cp $KEY              /opt/nomad/tls/tls.key
  sudo chmod -R go-rwx      /opt/nomad/tls
}


function setup-PV() {
  sudo mkdir -m777 -p /pv

  if [ "$NFS_PV" ]; then
    sudo apt-get install -yqq nfs-common
    echo "$NFS_PV /pv nfs proto=tcp,nosuid,hard,intr,actimeo=1,nofail,noatime,nolock,tcp 0 0" |sudo tee -a /etc/fstab
    sudo mount /pv
  fi
}


function setup-ctop() {
  # really nice `ctop` - a container monitoring more specialized version of `top`
  # https://github.com/bcicen/ctop
  echo "deb http://packages.azlux.fr/debian/ buster main" | sudo tee /etc/apt/sources.list.d/azlux.list
  wget -qO - https://azlux.fr/repo.gpg.key | sudo apt-key add -
  sudo apt-get -yqq update
  sudo apt-get install -yqq docker-ctop
}


function setup-404-page() {
  # sets up a "hostname not found" custom 404 page for fabio/LB to emit
  if [[ "${FIRST_FQDN?}" == *archive.org* ]]; then
    getr etc/archive.org/404.min.html
    consul kv put 'fabio/noroute.html' "$(cat /tmp/404.min.html)"
  fi
}


function getr() {
  # gets a supporting file from main repo into /tmp/
  wget --backups=1 -qP /tmp/ ${REPO}/"$1"
  chmod +x /tmp/$(basename "$1")
}


function finish() {
  set +x

  echo "

💥 CONGRATULATIONS!  Your cluster is setup. 💥

You can get started with the UI for: nomad consul fabio here:

Nomad  (deployment: managements & scheduling):
( https://www.nomadproject.io )
$NOMAD_ADDR
( login with NOMAD_TOKEN from $HOME/.config/nomad - keep this safe!)

Consul (networking: service discovery & health checks, service mesh, envoy, secrets storage):
( https://www.consul.io )
$CONSUL_ADDR

Fabio  (routing: load balancing, ingress/edge router, https and http2 termination (to http))
( https://fabiolb.net )
$FABIO_ADDR



For localhost urls above - see 'nom-tunnel' alias here:
  https://gitlab.com/internetarchive/nomad/-/blob/master/aliases

To uninstall:
  https://gitlab.com/internetarchive/nomad/-/blob/master/wipe-node.sh


"
}


main "$@"
