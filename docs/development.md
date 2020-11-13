## Prometheus
### In Openshit
One way to access Prometheus via openshift oauth proxy, provide token in HTTP header when quering Prometheus.
1. Provide ServiceAccount which has permission to list all namespace.


## Add new deployment
1. Add necessary kubernetes resource yaml files into [assets](./../assets). 
2. Get assets name by following steps.
- 2.1. Update bindata via command 'make pkg/assets/bindata.go'.
- 2.2. Inspecting [file](./../pkg/assets/bindata.go), and those new assets' name will be add as comment on top of the content.
3. Add new section set for new component as field into [AlamedaServiceSpec](./../pkg/apis/federatorai/v1alpha1/alamedaservice_types.go).
4. Seperate assets(output of step 2.2) and add into [file](./../pkg/processcrdspec/alamedaserviceparamter/alamedaserviceparamter.go).
- 4.1. Add PVC resources into [logPVCList](./../pkg/processcrdspec/alamedaserviceparamter/alamedaserviceparamter.go) and [dataPVCList](./../pkg/processcrdspec/alamedaserviceparamter/alamedaserviceparamter.go).
- 4.2. Declare new variable containing other resources.
    - 4.2.1 If this component needs to be installed in default, append this variable into variable [defaultInstallLists](./../pkg/processcrdspec/alamedaserviceparamter/alamedaserviceparamter.go). Otherwise, declare new function which will return this resource(Inspect function "GetWeavescopeResource" and check where is the function be called).
5. Update structure definition and constructure of AlamedaServiceParamter.
- 5.1. Add new component section set as field into [AlamedaServiceParamter](./../pkg/processcrdspec/alamedaserviceparamter/alamedaserviceparamter.go).
6. Add uninstall PVC logic into function [GetUninstallPersistentVolumeClaimSource](./../pkg/processcrdspec/alamedaserviceparamter/alamedaserviceparamter.go).
7. Add install PVC logic into function [getInstallPersistentVolumeClaimSource](./../pkg/processcrdspec/alamedaserviceparamter/alamedaserviceparamter.go).
8. Add image information.
- 8.1. Add constant variable for default image into [file](./../pkg/component/imageConfig.go).
- 8.2. Add new field into [ImageConfig](./../pkg/component/imageConfig.go).
- 8.3. Update constructor [NewDefautlImageConfig](./../pkg/component/imageConfig.go).
- 8.4. Add setter method for [ImageConfig](./../pkg/component/imageConfig.go) for later usage.
9. Add new constant into [file](./../pkg/controller/alamedaservice/util.go)
- 9.1. Append new environment variable into [relatedImageEnvList](./../pkg/controller/alamedaservice/util.go)
- 9.2. Add logic into function [setImageConfigWithAlamedaServiceParameter](./../pkg/controller/alamedaservice/util.go) which calling function(defining in step 8.4) to set image if user specify which image is used by this component from SectionSet(new section set define in AlamedaService in step 3)
- 9.3. Add new case into function [setImageConfigWithEnv](./../pkg/controller/alamedaservice/util.go) which calling function(defining in step 8.4) to set image if environment variable(defining in step 9.1) is not empty.
10. Add new constants into [file](./../pkg/util/util.go), these constant values must be the same as values yaml(i.e. files in step 1).
- 10.1. Add workload controller(Deployment/StatefulSet/DaemonSet) name.
- 10.2. Add container name.
11. Set global configuration, blow steps will use functions setting Deployment as example, use other functions for DaemonSet/StatefulSet.
- 11.1. Add new case into function [GlobalSectionSetParamterToDeployment](./../pkg/processcrdspec/globalsectionset/globalsectionset.go)
12. Set section configuration, blow steps will use functions setting Deployment as example, use other functions for DaemonSet/StatefulSet.
- 12.1. Add new case into function [SectionSetParamterToDeployment](./../pkg/processcrdspec/componentsectionset/componentsectionset.go).
- 12.2. Add new case into function [SectionSetParamterToPersistentVolumeClaim](./../pkg/processcrdspec/componentsectionset/componentsectionset.go).

## Assets yaml tamlplate
1. Transform to binary data with target in Makefile.
2. Function [Reconcile](./../pkg/controller/alamedaservice/alamedaservice_controller.go) will use [ComponentConfig](./../pkg/component/component.go) to pares values into these files.

## How does Federatorai-Operator automatically restart Pods when ConfigMap are update?
Limitation: 
1. Only Pods that are controlled by workload controller(i.e. Deployment/StatefulSet ...).
2. Procedure to deploy ConfigMap must those workload controller.

To let Federatorai-Operator restart Pods which mounting ConfigMap as volume, every synchronization functions(e.g. syncDeployment/syncStatefulSet/syncDaemonSet) will call [patchConfigMapResourceVersionIntoPodTemplateSpecLabel](./../pkg/controller/alamedaservice/alamedaservice_controller.go). This function will get the ConfigMap.Metadata.ResourceVersion and patch this value into PodTemplateSpec.Labels, so if the ConfigMap has been updated, the PodTemplateSpec will also be updated, those synchronization functions will update Deployment/StatefulSet/DaemonSet to trigger k8s restart these Pods.

## Code generation for CustomResource
To generate code that implements funciton "DeepCopy" in custom resource's structure, execute targe "code-gen" in Makefile.
For further usage of k8s code-gen tools, inspect [doc](#https://blog.openshift.com/kubernetes-deep-dive-code-generation-customresources/).