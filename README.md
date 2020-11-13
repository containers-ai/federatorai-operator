
# <a href="https://github.com/containers-ai/federatorai-operator"><img src="./logo.png" width=60/></a> Federator.ai Operator<a href="https://access.redhat.com/containers/?tab=overview#/registry.connect.redhat.com/prophetstor/federatorai-operator"><img src="./rhcert.png" align="right" width=150/></a>

**Federator.ai Operator** is an Operator that manages **Federator.ai** components for an OpenShift cluster. Once installed, the Federator.ai Operator provides the following features:
- **Create/Clean up**: Launch **Federator.ai** components using the Operator.
- **Easy Configuration**: Easily configure data source of Prometheus and enable/disable add-on components, such as GUI, and predictive autoscaling.
- **Pod Scaling Recommendation/Autoscaling**: Use provided CRD to setup target pods and desired policies for scaling recommendation and autoscaling.

> **Note:** **Federator.ai** requires a Prometheus datasource to get historical metrics of pods and nodes. When launching **Federator.ai** components, Prometheus connection settings need to be provided.

## Federator.ai

**Federator.ai** is the brain of resource orchestration for kubernetes. We use machine learning technology to provide intelligence that foresees future resource usage of your Kubernetes cluster across multiple layers. Federator.ai recommends the right sizes of containers and the right number of replications. It also elastically manages pod scaling and scheduling of your containerized applications. The benefits of **Federator.ai** include:
- Up to 60% resource savings
- Increased operational efficiency
- Reduced manual configuration time with digital intelligence

For more information, visit our [website](https://www.prophetstor.com/federator-ai/federator-ai-for-openshift/) and [github.com/containers-ai/alameda](https://github.com/containers-ai/alameda).

## Documentations
Please visit [docs](./docs/)

## Resources

* [How to Write Go Code](https://golang.org/doc/code.html)
* [Effective Go](https://golang.org/doc/effective_go.html)
* [Go Code Review Comments](https://github.com/golang/go/wiki/CodeReviewComments)
* [GitHub Flow](https://guides.github.com/introduction/flow/)
* [Go modules](https://github.com/golang/go/wiki/Modules)
* [Standard Go Project Layout](https://github.com/golang-standards/project-layout)
* [CRI tools](https://github.com/kubernetes-sigs/cri-tools)

## Usage

### Configuration

There are two method of configuration, the precedence from high to low is **Setting Environment Variable**, **Setting Configuration File**.

#### Setting Environment Variable

There are two types of environment variable that Federatorai-Operator accepts

* Variables with prefix **FEDERATORAI_OPERATOR**, the available variables list are identical to the configuration file. Properties in the configuration file tree are seperated with underscore("_"). For example, to configure the logger output level, set environment variable **FEDERATORAI_OPERATOR_LOG_OUTPUTLEVEL** to the desired value.

* Variables that are **not** with prefix **FEDERATORAI_OPERATOR**, the variables are listed below
  * name: WATCH_NAMESPACE
    * description: Federatorai-Operator will only reconcile AlamedaService in this namespace, or all namespaces if the variable is set to "".
  * name: POD_NAME
    * description: Federatorai-Operator will get the pod with this name that the pod is where the code is running at. It expects the environment variable POD_NAME to be set by the downwards API.
  * name: OPERATOR_NAME
    * description: Federatorai-Operator will create a service name in _OPERATOR_NAME_ to expose metrics service.  
  * name: DISABLE_OPERAND_RESOURCE_PROTECTION
    * description: If _true_ Federatorai-Operator will not reconcile k8s obejcts that are owned by AlamedaService when those objects have been changed individually, which means Federatorai-Operator will only reconcile those objects when AlamedaService has been changed.  

#### Setting Configuration File

See the example [file](./etc/operator.toml). Assign the configuration file path when running Federatorai-Operator with flag **--config**.
```
$FEDERATORAI_OPERATOR_BIN --config $CONFIGURATION_FILE_PATH
```

## Develop

### Requirements

* [operator-sdk v0.5.0](#https://github.com/operator-framework/operator-sdk)
