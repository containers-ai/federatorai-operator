# Metrics

## Step1

install alameda-ai and alameda-ai-dispatcher components

## Step2

### Apply AI Service Monitoring

alameda-ai-servicemonitoring-cr.yaml

<pre>
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: alameda-ai-metrics
  namespace: openshift-monitoring
  labels:
    <b>k8s-app: prometheus-operator</b>
    <b>release: prom</b>
spec:
  endpoints:
  - port: ai-metrics
  namespaceSelector:
    any: true
  selector:
    matchLabels:
      component: alameda-ai
</pre>

### Apply AI Dispatcher Service Monitoring

alameda-ai-dispatcher-servicemonitoring-cr.yaml

<pre>
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: alameda-ai-dispatcher-metrics
  namespace: openshift-monitoring
  labels:
    <b>k8s-app: prometheus-operator</b>
    <b>release: prom</b>
spec:
  endpoints:
  - port: ai-dispatcher-metrics
  namespaceSelector:
    any: true
  selector:
    matchLabels:
      component: alameda-ai-dispatcher
</pre>

***Labels of servicemonitoring must match service monitor selector of prometheus CR.*** To get
service monitor selector rule, run the following commands

#### Kubernetes
```bash
kubectl get prometheus -o=jsonpath="{.items[*].spec.serviceMonitorSelector}" -n monitoring
```
#### Openshift
```bash
kubectl get prometheus -o=jsonpath="{.items[*].spec.serviceMonitorSelector}" -n openshift-monitoring
```

## Step3

Update your clusterrole prometheus-k8s rbac

```

- apiGroups:
  - ""
  attributeRestrictions: null
  resources:
  - endpoints
  - pods
  - services
  verbs:
  - list


```
