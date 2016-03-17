#!/bin/bash
#
# kid is a helper script for launching Kubernetes in Docker
#
# TODO: Add a status command?
# TODO: Improvements documented throughout this file

KUBERNETES_VERSION=1.2.0
KUBERNETES_API_PORT=8080

set -e

function print_usage {
    cat << EOF
kid is a utility for launching Kubernetes in Docker

Usage: kid [command]

Available commands:
  up    Starts Kubernetes in the Docker host currently configured with your local docker command
  down  Tear down a previously started Kubernetes cluster
EOF
}

function check_prerequisites {
    function require_command_exists() {
        command -v "$1" >/dev/null 2>&1 || \
	    { echo "$1 is required but is not installed. Aborting." >&2; exit 1; }
    }
    require_command_exists kubectl
    require_command_exists docker
    docker info > /dev/null
    if [ $? != 0 ]; then
        echo A running Docker engine is required. Is your Docker host up?
        exit 1
    fi
}

function active_docker_machine {
    if [ $(command -v docker-machine) ]; then
        docker-machine active
    fi
}

function forward_port_if_not_forwarded {
    local port=$1
    local machine=$(active_docker_machine)

    if [ -n "$machine" ]; then
        if ! pgrep -f "ssh.*$port:localhost" > /dev/null; then
            docker-machine ssh "$machine" -f -N -L "$port:localhost:$port"
        else
            echo Did not set up port forwarding to the Docker machine: An ssh tunnel on port $port already exists. The kubernetes cluster may not be reachable from local kubectl.
        fi
    fi
}

function remove_port_if_forwarded {
    local port=$1
    pkill -f "ssh.*docker.*$port:localhost:$port"
}

function wait_for_kubernetes {
    echo Waiting for Kubernetes cluster to become available...
    until $(kubectl cluster-info &> /dev/null); do
        sleep 1
    done
    echo Kubernetes cluster is up.
}

function create_kube_system_namespace {
    # TODO: Suppress output
    kubectl create -f - << EOF
kind: Namespace
apiVersion: v1
metadata:
  name: kube-system
  labels:
    name: kube-system
EOF
}

function activate_kubernetes_dashboard {
    # TODO: Suppress output
    kubectl create -f - << EOF
kind: List
apiVersion: v1
items:
- kind: ReplicationController
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
      version: canary
    name: kubernetes-dashboard-canary
    namespace: kube-system
  spec:
    replicas: 1
    selector:
      app: kubernetes-dashboard-canary
      version: canary
    template:
      metadata:
        labels:
          app: kubernetes-dashboard-canary
          version: canary
      spec:
        containers:
        - name: kubernetes-dashboard-canary
          image: gcr.io/google_containers/kubernetes-dashboard-amd64:canary
          imagePullPolicy: Always
          ports:
          - containerPort: 9090
            protocol: TCP
          args:
            # Uncomment the following line to manually specify Kubernetes API server Host
            # If not specified, Dashboard will attempt to auto discover the API server and connect
            # to it. Uncomment only if the default does not work.
            # - --apiserver-host=http://my-address:port
          livenessProbe:
            httpGet:
              path: /
              port: 9090
            initialDelaySeconds: 30
            timeoutSeconds: 30
- kind: Service
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
    name: dashboard-canary
    namespace: kube-system
  spec:
    type: NodePort
    ports:
    - port: 80
      targetPort: 9090
      nodePort: 31999
    selector:
      app: kubernetes-dashboard-canary
    type: NodePort
EOF
}

function start_kubernetes {
    check_prerequisites

    if kubectl cluster-info 2> /dev/null; then
        echo kubectl is already configured to use an existing cluster
        exit 1
    fi

    docker run \
        --volume=/:/rootfs:ro \
        --volume=/sys:/sys:ro \
        --volume=/var/lib/docker/:/var/lib/docker:rw \
        --volume=/var/lib/kubelet/:/var/lib/kubelet:rw \
        --volume=/var/run:/var/run:rw \
        --net=host \
        --pid=host \
        --privileged=true \
        -d \
        gcr.io/google_containers/hyperkube-amd64:v${KUBERNETES_VERSION} \
        /hyperkube kubelet \
            --containerized \
            --hostname-override="127.0.0.1" \
            --address="0.0.0.0" \
            --api-servers=http://localhost:${KUBERNETES_API_PORT} \
            --config=/etc/kubernetes/manifests \
            --cluster-dns=10.0.0.10 \
            --cluster-domain=cluster.local \
            --allow-privileged=true --v=2 \
	> /dev/null

    forward_port_if_not_forwarded $KUBERNETES_API_PORT
    wait_for_kubernetes
    create_kube_system_namespace
    activate_kubernetes_dashboard
}

function delete_kubernetes_resources {
    # TODO: Find a guaranteed way to delete all the resources.
    # Do we need to delete them in specific a order?
    kubectl delete replicationcontrollers,services,pods,secrets --all
    sleep 3
    kubectl delete replicationcontrollers,services,pods,secrets --all --namespace=kube-system
    sleep 3
    kubectl delete namespace kube-system || :
    sleep 3
}

function delete_docker_containers {
    # TODO: Suppress all output, including errors
    docker ps | awk '{ print $1,$3 }' | grep "/hyperkube" | awk '{print $1 }' | xargs -I {} docker kill {} > /dev/null 2>&1
    docker kill $(docker ps -aq -f=ancestor=gcr.io/google_containers/hyperkube-amd64:v1.2.0) || : > /dev/null 2>&1
    docker kill $(docker ps -aq -f=name=k8s_) || : /dev/null 2>&1
    docker ps | awk '{ print $1,$3 }' | grep "/hyperkube" | awk '{print $1 }' | xargs -I {} docker rm {} > /dev/null 2>&1
    docker rm $(docker ps -aq -f=ancestor=gcr.io/google_containers/hyperkube-amd64:v1.2.0) > /dev/null 2>&1
    docker rm $(docker ps -aq -f=name=k8s_) > /dev/null 2>&1
}

function stop_kubernetes {
    delete_kubernetes_resources
    delete_docker_containers
    remove_port_if_forwarded $KUBERNETES_API_PORT
}

if [ "$1" == "up" ]; then
    start_kubernetes
elif [ "$1" == "down" ]; then
    stop_kubernetes
else
    print_usage
fi