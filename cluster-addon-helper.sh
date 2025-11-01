#!/bin/bash
set -euo pipefail

# Function: Install AWS Load Balancer Controller
install_lb_controller() {


    config_file=$1

    if [ ! -f "$config_file" ]; then

        echo "Error, Config file not found"

    fi

    CLUSTER_NAME=$(yq " .metadata.name " "$config_file")

    REGION=$(yq " .metadata.region " "$config_file")

    echo "🔧 Installing AWS Load Balancer Controller on cluster: $CLUSTER_NAME in region: $REGION"

    # 1. Associate IAM OIDC provider
    eksctl utils associate-iam-oidc-provider --region "$REGION" --cluster "$CLUSTER_NAME" --approve

    # 2. Create IAM policy for AWS Load Balancer Controller
    curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam-policy.json || echo "⚠️ Policy may already exist, continuing..."

    # 3. Create IAM service account for the controller
    eksctl create iamserviceaccount \
        --cluster "$CLUSTER_NAME" \
        --namespace kube-system \
        --name aws-load-balancer-controller \
        --attach-policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
        --approve

    # 4. Add and update Helm repo
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update

    # 5. Install controller via Helm
    helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --set region="$REGION"

    echo "✅ AWS Load Balancer Controller installed successfully!"
}

# Function: Delete AWS Load Balancer Controller
delete_lb_controller() {

    config_file=$1

    if [ ! -f "$config_file" ]; then

        echo "Error, Config file not found"

    fi

    CLUSTER_NAME=$(yq " .metadata.name " "$config_file")

    REGION=$(yq " .metadata.region " "$config_file")

    echo "🧹 Deleting AWS Load Balancer Controller from cluster: $CLUSTER_NAME"

    # 1. Uninstall Helm release
    helm uninstall aws-load-balancer-controller -n kube-system || echo "⚠️ Helm release not found"

    # 2. Delete IAM service account
    eksctl delete iamserviceaccount \
        --cluster "$CLUSTER_NAME" \
        --namespace kube-system \
        --name aws-load-balancer-controller \
        --wait || echo "⚠️ IAM service account not found"

    # 3. Delete IAM policy (optional)
    POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy"
    aws iam delete-policy --policy-arn "$POLICY_ARN" || echo "⚠️ Policy not found or already deleted"

    echo "✅ AWS Load Balancer Controller deleted successfully!"
}

install_autoscaler() {
    
    
    config_file=$1

    if [ ! -f "$config_file" ]; then

        echo "Error, Config file not found"

    fi

    CLUSTER_NAME=$(yq " .metadata.name " "$config_file")

    REGION=$(yq " .metadata.region " "$config_file")

    HELM_RELEASE_NAME="cluster-autoscaler"

    NAMESPACE="kube-system"

    echo "🔧 Installing Cluster Autoscaler on EKS cluster: $CLUSTER_NAME"

    # Get the EKS cluster's AWS account ID and region
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    # Create a service account with required permissions (IRSA)
    eksctl create iamserviceaccount \
      --cluster "$CLUSTER_NAME" \
      --namespace "$NAMESPACE" \
      --name "$HELM_RELEASE_NAME" \
      --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy \
      --approve \
      --override-existing-serviceaccounts || true

    # Add helm repo if not added
    helm repo add autoscaler https://kubernetes.github.io/autoscaler
    helm repo update

    # Install cluster-autoscaler
    helm upgrade --install "$HELM_RELEASE_NAME" autoscaler/cluster-autoscaler-chart \
      --namespace "$NAMESPACE" \
      --set autoDiscovery.clusterName="$CLUSTER_NAME" \
      --set awsRegion="$AWS_REGION" \
      --set rbac.serviceAccount.create=false \
      --set rbac.serviceAccount.name="$HELM_RELEASE_NAME" \
      --set extraArgs.balance-similar-node-groups=true \
      --set extraArgs.skip-nodes-with-system-pods=false \
      --set extraArgs.skip-nodes-with-local-storage=false

    echo "✅ Cluster Autoscaler installed successfully!"
    
}

uninstall_autoscaler() {
    
    config_file=$1

    if [ ! -f "$config_file" ]; then

        echo "Error, Config file not found"

    fi

    CLUSTER_NAME=$(yq " .metadata.name " "$config_file")

    REGION=$(yq " .metadata.region " "$config_file")

    HELM_RELEASE_NAME="cluster-autoscaler"

    NAMESPACE="kube-system"

    echo "🧹 Uninstalling Cluster Autoscaler from EKS cluster: $CLUSTER_NAME"

    helm uninstall "$HELM_RELEASE_NAME" -n "$NAMESPACE" || echo "autoscaler not found"

    eksctl delete iamserviceaccount \
      --cluster "$CLUSTER_NAME" \
      --namespace "$NAMESPACE" \
      --name "$HELM_RELEASE_NAME" || echo "autoscaler serviceaccount not found"

    echo "✅ Cluster Autoscaler uninstalled successfully!"

}


# --- Function: Install Kubewatch ---
install_kubewatch() {

  config_file=$1

  if [ ! -f "$config_file" ]; then

    echo "Error, Config file not found"

  fi

  CLUSTER_NAME=$(yq " .metadata.name " "$config_file")

  REGION=$(yq " .metadata.region " "$config_file")

  NAMESPACE="kubewatch"
  RELEASE_NAME="kubewatch"
  VALUES_FILE="/addon-config/kube-watch-values.yaml"
  CHART_REPO="robusta"
  CHART_NAME="kubewatch"

  echo "🚀 Installing Kubewatch..."

  # Create namespace if it doesn't exist
  if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    echo "📦 Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
  fi

  echo "🔗 Adding $CHART_REPO Helm repo..."
  helm repo add "$CHART_REPO" https://robusta-charts.storage.googleapis.com

  # Update repos
  echo "🔄 Updating Helm repos..."
  helm repo update


  # modify channel configs

  allchannels="slack slackwebhook hipchat mattermost flock msteams webhook cloudevent lark smtp"

  channels=$(yq " .extraAddons[] | select(.name="kube-watch") | .config.channels[].name " "$config_file")

  for achannel in $allchannels; do
    channel_exists=$(echo $channels | grep -qw "$achannel")
    if [ -z $channel_exists ]; then
        
        disable_query=$(echo " .${achannel}.enabled=false")
        yq -i "$disable_query" "$VALUES_FILE"

    else

        if [ "$achannel"="slack" ]; then
            
            schannel=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.channel ' '$config_file'  )
            stoken=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.token ' '$config_file')
            enabled_q=$(echo " .${achannel}.enabled=true ")
            schannel_q=$(echo " .${achannel}.channel=${schannel} ")
            stoken_q=$(echo " .${achannel}.token=${token} ")
            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$schannel_q" "$VALUES_FILE"
            yq -i "$stoken_q" "$VALUES_FILE"

        fi


        if [ "$achannel"="slackwebhook" ]; then

            schannel=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.channel ' '$config_file'  )
            susername=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.username ' '$config_file'  )
            semoji=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.emoji ' '$config_file' )
            sslackwebhookurl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.emoji ' '$config_file' )

            enabled_q=$(echo " .${achannel}.enabled=true ")
            schannel_q=$(echo " .${achannel}.channel=${schannel} ")
            susername_q=$(echo " .${achannel}.username=${susername} " )
            semoji_q=$(echo " .${achannel}.emoji=${semoji} " )
            sslackwebhookurl_q=$(echo " .${achannel}.emoji=${sslackwebhookurl} " ) 
            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$schannel_q" "$VALUES_FILE"
            yq -i "$susername_q" "$VALUES_FILE"
            yq -i "$semoji_q" "$VALUES_FILE"
            yq -i "$sslackwebhookurl_q" "$VALUES_FILE"

        fi


        if [ "$achannel"="hipchat" ]; then

            hroom=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.room ' '$config_file')
            htoken=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.token ' '$config_file')
            hurl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.url ' '$config_file')

            enabled_q=$(echo ' .${achannel}.enabled=true ')
            hroom_q=$(echo ' .${achannel}.room=${hroom} ')
            htoken_q=$(echo ' .${achannel}.token=${htoken} ')
            hurl_q=$(echo ' .${achannel}.url=${hurl} ' )

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$hroom_q" "$VALUES_FILE"
            yq -i "$htoken_q" "$VALUES_FILE"
            yq -i "$hurl_q" "$VALUES_FILE"

        fi

        if [ "$achannel"="mattermost" ]; then

            mchannel=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.channel ' '$config_file')
            murl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.url ' '$config_file')
            musername=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.username ' '$config_file')
            
            enabled_q=$(echo ' .${achannel}.enabled=true ')
            mchannel_q=$(echo ' .${achannel}.channel=${mchannel} ')
            murl_q=$(echo ' .${achannel}.url=${murl} ')
            musername_q=$(echo ' .${achannel}.url=${musername} ')

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$mchannel_q" "$VALUES_FILE"
            yq -i "$murl_q" "$VALUES_FILE"
            yq -i "$musername_q" "$VALUES_FILE"


        fi


        if [ "$achannel"="flock" ]; then

            furl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.url ' '$config_file')
            
            enabled_q=$(echo ' .${achannel}.enabled=true ')
            furl_q=$(echo ' .${achannel}.url=${furl} ')

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$furl_q" "$VALUES_FILE"

        fi


        if [ "$achannel"="msteams" ]; then

            mswebhookurl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.webhookurl ' '$config_file')

            enabled_q=$(echo ' .${achannel}.enabled=true ')
            mswebhookurl_q=$(echo ' .${achannel}.webhookurl=${mswebhookurl} ')

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$mswebhookurl_q" "$VALUES_FILE"

        fi

        if [ "$achannel"="webhook" ]; then

            wurl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.url ' '$config_file')

            enabled_q=$(echo ' .${achannel}.enabled=true ')
            wurl_q=$(echo ' .${achannel}.url=${wurl} ')

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$wurl_q" "$VALUES_FILE"

        fi

        if [ "$achannel"="cloudevent" ]; then

            curl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.url ' '$config_file')

            enabled_q=$(echo ' .${achannel}.enabled=true ' )
            curl_q=$(echo ' .${achannel}.url=${curl} ' )

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$curl_q" "$VALUES_FILE"


        fi

        if [ "$achannel"="lark" ]; then

            lwebhookurl=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.webhookurl ' '$config_file')

            enabled_q=$(echo ' .${achannel}.enabled=true ' )
            curl_q=$(echo ' .${achannel}.webhookurl=${lwebhookurl} ' )

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$curl_q" "$VALUES_FILE"


        fi


        if [ "$achannel"="smtp" ]; then

            sto=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.to ' '$config_file')
            sfrom=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.from ' '$config_file')
            shello=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.hello ' '$config_file')
            ssmarthost=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.smarthost ' '$config_file')
            ssubject=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.subject ' '$config_file')
            username=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.auth.username ' '$config_file')
            password=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.auth.password ' '$config_file')
            secret=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.auth.secret ' '$config_file')
            identity=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.auth.identity ' '$config_file')
            requireTLS=$(channel=$achannel yq ' .extraAddons[] | select(.name="kube-watch") | .config.channels[] | select(.name=strenv(channel)) | .config.requireTLS ' '$config_file')

            enabled_q=$(echo ' .${achannel}.enabled=true ')
            sto_q=$(echo ' .${achannel}.to=${sto} ')
            sfrom_q=$(echo ' .${achannel}.from=${sfrom} ')
            shello_q=$(echo ' .${achannel}.hello=${shello} ')
            ssmarthost_q=$(echo ' .${achannel}.smarthost=${ssmarthost} ')
            ssubject_q=$(echo ' .${achannel}.subject=${ssubject} ')
            username_q=$(echo ' .${achannel}.auth.username=${username} ')
            password_q=$(echo ' .${achannel}.auth.password=${password} ')
            secret_q=$(echo ' .${achannel}.auth.secret=${secret} ')
            identity_q=$(echo ' .${achannel}.auth.identity=${identity} ')
            requireTLS_q=$(echo ' .${achannel}.requireTLS=${requireTLS} ')

            yq -i "$enabled_q" "$VALUES_FILE"
            yq -i "$sto_q" "$VALUES_FILE"
            yq -i "$sfrom_q" "$VALUES_FILE"
            yq -i "$shello_q" "$VALUES_FILE"
            yq -i "$ssmarthost_q" "$VALUES_FILE"
            yq -i "$ssubject_q" "$VALUES_FILE"
            yq -i "$username_q" "$VALUES_FILE"
            yq -i "$password_q" "$VALUES_FILE"
            yq -i "$secret_q" "$VALUES_FILE"
            yq -i "$identity_q" "$VALUES_FILE"
            yq -i "$requireTLS_q" "$VALUES_FILE"

        fi


    fi
  done

  # Install or upgrade release
  echo "📥 Installing/Upgrading Kubewatch with values from $VALUES_FILE..."
  helm upgrade --install "$RELEASE_NAME" "$CHART_REPO/$CHART_NAME" \
    --namespace "$NAMESPACE" \
    -f "$VALUES_FILE"

  

  echo "✅ Kubewatch installation complete!"

}


uninstall_kubewatch() {
  
  echo "🧹 Uninstalling Kubewatch..."

  NAMESPACE="kubewatch"
  RELEASE_NAME="kubewatch"
  VALUES_FILE="/addon-config/kube-watch-values.yaml"
  CHART_REPO="robusta"
  CHART_NAME="kubewatch"
  
  echo "🚀 Installing Kubewatch..."

  if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
    echo "✅ Kubewatch release removed."
  else
    echo "⚠️ Kubewatch is not installed in namespace $NAMESPACE."
  fi

}


install_kube_prometheus() {

    NAMESPACE="monitoring"
    RELEASE_NAME="kube-prometheus"
    CHART_REPO="https://prometheus-community.github.io/helm-charts"
    CHART_NAME="prometheus-community/kube-prometheus-stack"

    echo "🔹 Creating namespace: $NAMESPACE (if not exists)"
    kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

    echo "🔹 Adding Prometheus Helm repo..."
    helm repo add prometheus-community "$CHART_REPO" >/dev/null
    helm repo update >/dev/null

    echo "🔹 Installing kube-prometheus-stack without public LoadBalancer..."
    helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
        --namespace "$NAMESPACE" \
        --set grafana.service.type=ClusterIP \
        --set prometheus.service.type=ClusterIP \
        --set alertmanager.service.type=ClusterIP \
        --set prometheusOperator.admissionWebhooks.patch.enabled=false \
        --wait

    echo "✅ Kube Prometheus installed successfully."
    echo "ℹ️ Access via port-forward:"
    echo "   kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME-grafana 3000:80"
    echo "   kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME-prometheus 9090:9090"
}

uninstall_kube_prometheus() {
    
    NAMESPACE="monitoring"
    RELEASE_NAME="kube-prometheus"
    CHART_REPO="https://prometheus-community.github.io/helm-charts"
    CHART_NAME="prometheus-community/kube-prometheus-stack"
    
    echo "🔹 Uninstalling kube-prometheus-stack..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true

    echo "🔹 Deleting namespace: $NAMESPACE..."
    kubectl delete ns "$NAMESPACE" --ignore-not-found

    echo "✅ Kube Prometheus uninstalled successfully."
}