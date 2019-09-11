#!/bin/bash

assign-role-to-ns() {
  declare desc="creates namespace restricted serviceaccount"
  declare namespace=${1}
  : ${namespace:? required}
  : ${workshopNamespace:? required}

  cat << EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sa-${namespace}
  namespace: ${workshopNamespace}
  labels:
    user: "${namespace}"
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: role-${namespace}
  namespace: ${namespace}
  labels:
    user: "${namespace}"
rules:
- apiGroups: ["", "extensions", "apps", "autoscaling"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["batch"]
  resources:
  - jobs
  - cronjobs
  verbs: ["*"]
- apiGroups: ["networking.istio.io"]
  resources:
  - virtualservices
  - gateways
  - destinationrules
  verbs: ["*"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources:
  - roles
  - rolebindings
  verbs: ["*"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources:
  - clusterroles
  - clusterrolebindings
  verbs:
  - get
  - list
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: rb-${namespace}
  namespace: ${namespace}
  labels:
    user: "${namespace}"
subjects:
- kind: ServiceAccount
  name: sa-${namespace}
  namespace: ${workshopNamespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: role-${namespace}
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: rb-def-${namespace}
  namespace: ${namespace}
  labels:
    user: "${namespace}"
subjects:
- kind: ServiceAccount
  name: default
  namespace: ${mamespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: role-${namespace}
EOF
}

## kubectl wait isnt available with v1.10
wait-for-deployment() {
  declare deployment=${1}
  : ${deployment:? required}

  while ! [[ 1 -eq $(kubectl get deployments ${deployment} -o jsonpath='{.status.readyReplicas}' 2> /dev/null) ]]; do
    echo -n .
    sleep 1
  done
}

namespace() {
    declare namespace=${1}
    : ${namespace:? required}
    : ${workshopNamespace:? required}

    kubectl create ns ${namespace}
    kubectl label ns ${namespace} user=${namespace} 
    assign-role-to-ns ${namespace} | kubectl create -f -

    kubectl create clusterrolebinding crb-${namespace} --clusterrole=lister --serviceaccount=${workshopNamespace}:sa-${namespace}
    kubectl label clusterrolebinding crb-${namespace} user=${namespace} 
    kubectl create clusterrolebinding crb-cc-${namespace} --clusterrole=common-config --serviceaccount=${workshopNamespace}:sa-${namespace}
    kubectl label clusterrolebinding crb-cc-${namespace} user=${namespace} 
    
}

enable-namespaces() {

  if ! kubectl get validatingwebhookconfiguration workshopnamespacevalidator -o name 2> /dev/null ;then
    # right now de deployer only works in the default ns
    origns=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}')
    kubectl config set-context $(kubectl config current-context) --namespace=default
    kubectl apply -f https://raw.githubusercontent.com/lalyos/k8s-ns-admission/master/deploy-webhook-job.yaml
    kubectl config set-context $(kubectl config current-context) --namespace=${origns}
  fi 
  kubectl patch clusterrole lister --patch='{"rules":[{"apiGroups":[""],"resources":["nodes","namespaces"],"verbs":["*"]}]}'
}

disable-namespaces() {
  kubectl patch clusterrole lister --patch='{"rules":[{"apiGroups":[""],"resources":["nodes","namespaces"],"verbs":["get","list","watch"]}]} '
}

depl() {
  declare namespace=${1}
  : ${domain:=k8z.eu}
  : ${namespace:? required}
  : ${gitrepo:=https://github.com/ContainerSolutions/ws-kubernetes-essentials-app.git}

  local name=${namespace}

cat <<EOF
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  labels:
    user: "${namespace}"
    run: ${name}
  name: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      run: ${name}
  template:
    metadata:
      labels:
        run: ${name}
    spec:
      serviceAccountName: sa-${name}
      volumes:
        - name: gitrepo
          gitRepo:
            repository: ${gitrepo}
            directory: .
      containers:
      - args:
        - gotty
        - "-w"
        - "-r"
        - "--title-format=${name}"
        #- tmux
        - bash
        env:
          - name: NS
            value: ${name}
          - name: TILLER_NAMESPACE
            value: ${name} 
          - name: NODE
            valueFrom:
              fieldRef:
                fieldPath: spec.nodeName
          - name: SA
            valueFrom:
              fieldRef:
                fieldPath: spec.serviceAccountName
          - name: TERM
            value: xterm
        image: lalyos/k8s-workshop
        name: dev
        volumeMounts:
          - mountPath: /root/workshop
            name: gitrepo 
---
apiVersion: v1
kind: Service
metadata:
  labels:
    user: "${namespace}"
    run: ${name}
  name: ${name}
spec:
  ports:
  - port: 8080
    protocol: TCP
    targetPort: 8080
  selector:
    run: ${name}
  type: NodePort
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  annotations:
    nginx.org/websocket-services: ${name}
  labels:
    user: "${namespace}"
  name: ${name} 
spec:
  rules:
  - host: ${name}.${domain}
    http:
      paths:
      - backend:
          serviceName: ${name}
          servicePort: 8080
EOF
}

dev() {
    declare namespace=${1}
    : ${namespace:? required}
    : ${workshopNamespace:? required}
    
    namespace ${namespace}
    namespace ${namespace}play
    kubectl create rolebinding crb-${namespace}-x \
      --role=role-${namespace}play \
      --namespace=${namespace}play \
      --serviceaccount=${workshopNamespace}:sa-${namespace}

    depl ${namespace}| kubectl create -f - 

    wait-for-deployment ${namespace}
    get-url ${namespace} 
}

presenter() {
   local pod=$(kubectl get po -l run=user0 -o jsonpath='{.items[0].metadata.name}')
   #kubectl exec -t $pod -- tmux new-session -s delme -d  2>/dev/null
   kubectl exec -it $pod -- tmux new-session -A -s presenter
}

presenter-url() {
    if ! kubectl get svc presenter &> /dev/null; then
      local pod=$(kubectl get po -l run=user0 -o jsonpath='{.items[0].metadata.name}')
      #kubectl exec -it $pod -- bash -c "gotty -p 8888 tmux attach -r -t presenter &"
      kubectl exec -it $pod -- bash -c "nohup /usr/local/bin/gotty -p 8888 --title-format=presenter tmux attach -r -t presenter &"
      kubectl expose deployment user0 --port 8888 --type=NodePort --name presenter
    fi

   externalip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type == "ExternalIP")].address}') 
   kubectl get svc presenter -o jsonpath="open http://${externalip}:{.spec.ports[0].nodePort}"
   echo
}

get-url() {
    declare deployment=${1}

    : ${deployment:? required}
    pod=$(kubectl get po -lrun=${deployment} -o jsonpath='{.items[0].metadata.name}')
    rndPath=$(kubectl logs ${pod} |sed -n '/HTTP server is listening at/ s/.*:8080//p')

    sessionurl=$(kubectl get deployments. ${deployment} -o jsonpath='{.metadata.annotations.sessionurl}')
    newSessionUrl="${sessionurl%/*/}${rndPath}"
    kubectl annotate deployments ${deployment} --overwrite sessionurl="${newSessionUrl}"
    
    externalip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type == "ExternalIP")].address}') 
    nodePort=$(kubectl get svc ${deployment} -o jsonpath="{.spec.ports[0].nodePort}")
    sessionUrlNodePort="http://${externalip}:${nodePort}${rndPath}"
    kubectl annotate deployments ${deployment} --overwrite sessionurlnp=${sessionUrlNodePort}

    echo "open ${sessionUrlNodePort}"
    echo "open ${newSessionUrl}"

}

init() {
    : ${userEmail:=$(gcloud auth list --format="value(account)" --filter=status:ACTIV 2>/dev/null)}
    : ${workshopNamespace:=workshop}
    : ${gitrepo:=https://github.com/ContainerSolutions/ws-kubernetes-essentials-app.git}

    workshop-context
    init-firewall

    if ! kubectl get clusterrolebinding cluster-admin-binding &> /dev/null; then
      kubectl create clusterrolebinding cluster-admin-binding \
        --clusterrole cluster-admin \
        --user ${userEmail}
     fi

    # In case the above doesn't work ask the account owner to do:
    # prj=$(gcloud config get-value project 2>/dev/null)
    # gcloud projects add-iam-policy-binding $prj --member=$userEmail --role=roles/container.admin

    if ! kubectl get clusterrole lister &> /dev/null; then
      kubectl create clusterrole lister \
        --verb=get,list,watch \
        --resource=nodes,namespaces
        kubectl label clusterrole lister user=workshop
    fi

    if ! kubectl get clusterrole common-config &> /dev/null; then
      kubectl create clusterrole common-config \
        --verb=list,get,watch \
        --resource=configmaps \
        --resource-name=common
        kubectl label clusterrole common-config user=workshop
    fi
}

init-firewall() {
  if gcloud compute firewall-rules describe external-nodeports &> /dev/null; then
    echo "---> firewall is already opened for NodePorts"
    return
  fi

  echo "---> open up firewall for NodePorts (30000-32767)"
  gcloud compute firewall-rules create external-nodeports \
   --description="allow external access to k8s nodeport" \
   --direction=INGRESS \
   --priority=1000 \
   --network=default \
   --action=ALLOW \
   --rules=tcp:30000-32767 \
   --source-ranges=0.0.0.0/0
}

workshop-context() {
  : ${workshopNamespace:? required}

  if [[ "$KUBECONFIG" == "$PWD/config-workshop.yaml" ]]; then
    echo "---> workshop context already set. To return to original context:"
    echo "--->   export KUBECONFIG=$PWD/config-orig.yaml"
    return
  fi
  kubectl config view --minify --flatten > config-orig.yaml
  kubectl create ns ${workshopNamespace} 
  cp config-orig.yaml config-workshop.yaml 
  export KUBECONFIG=$PWD/config-workshop.yaml
  kubectl config set-context $(kubectl config current-context) --namespace=${workshopNamespace}
  echo "---> context set to use namespace: ${workshopNamespace}, by:"
  echo "export KUBECONFIG=$KUBECONFIG"
}

clean-user() { 
    ns=$1;
    : ${ns:?required};

    kubectl delete all,ns,sa,clusterrolebinding,ing -l "user in (${ns},${ns}play)"
}

list-sessions() {
  echo "=== unassigned sessions:"
  kubectl get deployments --all-namespaces -l 'user,!ghuser'
  echo "=== assigned sessions:"
  kubectl get deployments \
    --all-namespaces \
    -l ghuser \
    -o custom-columns='NAME:.metadata.name,GHUSER:.metadata.labels.ghuser,URL1:.metadata.annotations.sessionurl,URL2:.metadata.annotations.sessionurlnp'
}

init-ingress() {
  # check that default GLBC plugin is stopped
  glbc=$(kubectl get deployments,svc -n kube-system -lk8s-app=glbc 2>/dev/null)
  if [[ "$glbc" ]]; then
    cat << EOF
[WARNING] defult glbc addon should be disabled
  - navigate to: https://console.cloud.google.com/kubernetes/list
  - choose cluster
  - "edit"
  - open "Add-ons" section
  - disable "HTTP load balancing"
  - "save"
EOF
    return
  fi
  echo "---> check default GLBC plugin is disbled: ok"

  if kubectl get ns ingress-nginx &> /dev/null; then
    echo "---> ingress-nginx is already deployed ..."
  else
    # https://kubernetes.github.io/ingress-nginx/deploy/#gce-gke
    echo "---> create: ns,cm,sa,crole,dep"
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/mandatory.yaml
    echo "---> creates single LB" 
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/cloud-generic.yaml
  fi

  ingressip=$(kubectl get svc -n ingress-nginx ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

  echo "---> checking DNS A record (*.${domain}) points to: $ingressip ..." 
  if [[ $(dig +short *.${domain}) == $ingressip ]] ; then 
    echo "DNS setting are ok"
  else 
    echo "---> set external dns A record (*.${domain}) to: $ingressip"
  fi
}
main() {
  : DEBUG=1
  init

}
