# QuickStart

The **Federator.ai Operator** is an operator that manage [Federator.ai](https://github.com/containers-ai/alameda) in ways of:
- Deployment
- Upgrade
- Application Lifecycle and storage

And this document helps you to get started. In the following sections, we first show how to install **Federator.ai Operator** and then how to use it.

## Deployment

Like any Kubernetes application, the deployment of a Kubernetes application can directly apply Kubernetes manifests or leverage 3rd-party tools/frameworks. Here we provide but not limited to two ways:
- by Kubernetes manifests
- by operator-lifecycle-management framework

During the deployment, **Federator.ai Operator** will install a CRD called _AlamedaService_ as a channel for users to interact with it. **Federator.ai Operator** will reconcile to an _AlamedaService_ CR in a cluster wide scope.

#### Deployment by Kubernetes Manifests

1. The installation script on github helps install Federator.ai on your cluster by applying Kubernetes manifests.
```
$ curl https://raw.githubusercontent.com/containers-ai/federatorai-operator/v4.2.301/deploy/install.sh |bash
```

2. Follow the prompts to enter the version number and namespace where Federator.ai will be installed in.

**Note:** The script also provides non-interactive installation. Please see the comments in the front of the script for examples.

#### Deployment by Operator-Lifecycle-Management Framework

[Operator-Lifecycle-Management(OLM)](https://github.com/operator-framework/operator-lifecycle-manager) extends Kubernetes to provide a declarative way to install, manage, and upgrade operators and their dependencies in a cluster. To deploy **Federator.ai Operator** by OLM, please follow the instructions at [OperatorHub.io](https://operatorhub.io/operator/federatorai). Here copies the instructions as a quick reference.

1. Install OLM first
```
$ curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/0.12.0/install.sh | bash -s 0.12.0
```

2. Install **Federator.ai Operator**
```
$ kubectl create -f https://operatorhub.io/install/federatorai.yaml
```
This will pull image from `quay.io/prophetstor` and install **Federator.ai Operator** version 4.2.301 to `operators` namespace. You should see `federatorai-operator` pod is running after few seconds.

## Using Federator.ai Operator

To use **Federator.ai Operator**, users need to create/apply an _AlamedaService_ CR in the namespace. Here is an example of _AlamedaService_ CR.
```
apiVersion: federatorai.containers.ai/v1alpha1
kind: AlamedaService
metadata:
  name: my-alamedaservice
  namespace: federatorai
spec:
  keycode:
    codeNumber: D3JXN-LIFTQ-KQEZ3-WZBNI-DA3WZ-A7HKQ		## default trial keycode
  selfDriving: false            ## to enable resource self-orchestration of the deployed Federator.ai components
                                ## it is recommended NOT to use ephemeral data storage for Alameda influxdb component when self-Driving is enabled	
  enableExecution: false
  enableGui: false
  enableFedemeter: true
  enableDispatcher: false

  version: v4.2.301             ## for Federator.ai components. (exclude influxdb)
  prometheusService: https://prometheus-k8s.openshift-monitoring:9091
  storages:                     ## see following details for where it is used in each component
    - usage: log                ## storage setting for log
      type: ephemeral           ## ephemeral means emptyDir{}
    - usage: data               ## storage setting for data
      type: pvc                 ## pvc means PersistentVolumeClaim
      size: 10Gi                ## mandatory when type=pvc
      class: "normal"           ## mandatory when type=pvc
```
By creating this CR, **Federator.ai Operator** starts to:
- deploy Federator.ai core components, components for recommendation execution and components for GUI
- pull Federator.ai component images on the tag specified by _version_ except InfluxDB image is on '1.7-alpine' tag. To overwrite the pulled image tag of InfluxDB, users can specify it in _section schema_.
- set Alameda datahub to retrieve metrics from Prometheus at the address defined by _prometheusService_
- mount _emptyDir{}_ to log path for each component
- claim volume by PVC and mount it to data path for each component

For more details, please refer to [AlamedaService CRD document](./crd_alamedaservice.md).


In addition, users can patch a created _AlamedaService_ CR and **Federator.ai Operator** will react to it. For example, by changing the _enableExecution_ field from _true_ to _false_, Alameda recommendation execution components will be uninstalled. (Alameda is still giving prediction and recommendations. GUI can still visualize the result. Just the execution part is off)

After Federator.ai is successfully installed, the next step is to create _AlamedaScaler_ CRs to start configuring and using Federator.ai. Please refer to [_AlamedaScaler_ document](https://github.com/containers-ai/alameda/blob/master/docs/quickstart.md) for more details.


## Teardown

Execute the uninstall script and follow the prompts.
```
$ curl https://raw.githubusercontent.com/containers-ai/federatorai-operator/v4.2.301/deploy/uninstall.sh |bash
```


