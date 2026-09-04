# LibreTranslate Helm Chart

This Helm chart deploys a LibreTranslate instance on a Kubernetes cluster using the Helm package manager.

## Prerequisites

- Kubernetes 1.12+
- Helm 3.0+

## Installing the Chart

To install the chart with the release name `libretranslate`:

```bash
helm install libretranslate ./chart --namespace libretranslate --create-namespace
```

This command deploys LibreTranslate on the Kubernetes cluster with the default configuration. The [values.yaml](values.yaml) file lists the parameters that can be configured during installation.

> **Tip**: List all releases using `helm list`

## Uninstalling the Chart

To uninstall/delete the `libretranslate` deployment:

```bash
helm delete libretranslate
```

This command removes all the Kubernetes components associated with the chart and deletes the release.

## Configuration

See [values.yaml](values.yaml) for the full list of parameters that can be configured. You can specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example,

```bash
helm install libretranslate ./chart --namespace libretranslate --create-namespace --set service.port=8080
```

Alternatively, a YAML file that specifies the values for the parameters can be provided while installing the chart. For example,

```bash
helm install libretranslate ./chart --namespace libretranslate --create-namespace -f values.yaml
```

## OpenShift / OKD

OpenShift's default `restricted-v2` SCC assigns every pod an arbitrary UID and
fsGroup from the namespace's allocated range, and rejects pods that pin their own
IDs or run a container as root. The chart defaults do both, so set the OpenShift
flag instead:

```bash
helm install libretranslate ./chart --namespace libretranslate --create-namespace \
  --set openshift.enabled=true
```

That does not require an SCC of its own - the rendered pod satisfies
`restricted-v2` (and the Pod Security Admission `restricted` profile) as is:

| | `openshift.enabled=false` | `openshift.enabled=true` |
| --- | --- | --- |
| `securityContext.fsGroup` | `1032` | dropped, assigned by the SCC |
| `podSecurityContext.runAsUser` / `runAsGroup` | `1032` / `1032` | dropped, assigned by the SCC |
| `seccompProfile` | `RuntimeDefault` | `RuntimeDefault` |
| `capabilities` | `drop: [ALL]` | `drop: [ALL]` |
| `allowPrivilegeEscalation` | `false` | `false` |
| init container | runs as root to `chown` the volumes | runs as the pod user, no `chown` |
| models / db dirs without persistence | image directories | `emptyDir` volumes |

Two details follow from the arbitrary UID and are handled automatically:

- `HOME` is exported explicitly (`homeDir`, default `/home/libretranslate`). The
  assigned UID has no `/etc/passwd` entry, so without it Python resolves `~` to
  `/` and argos-translate looks for the language models in the wrong place.
- `XDG_CACHE_HOME` is pointed at `openshift.cacheDir` (default `/tmp/.cache`),
  because the image owns `$HOME` as UID 1032 and an arbitrary UID cannot create
  `$HOME/.local/cache`.
- When `persistence.enabled` is `false`, the model and database directories are
  backed by `emptyDir` volumes rather than the image-owned paths, which the
  arbitrary UID cannot write to. The models are re-downloaded on every pod
  restart, so enable `persistence` for anything but a quick trial.

If your cluster grants the service account the `nonroot-v2` SCC instead, you can
leave `openshift.enabled=false` and keep the pinned UID 1032 that matches the
image.

## Upgrade

Run the following command to upgrade your LibreTranslate installation. This command will use the Helm chart in the ./chart directory, apply the custom values from values.yaml, and deploy the upgrade to the `libretranslate` namespace:

```bash
helm upgrade --install libretranslate ./chart --namespace libretranslate -f values.yaml
```

> **Tip**: You can use the default [values.yaml](values.yaml)

# References
- [https://jmrobles.medium.com/libretranslate-your-own-translation-service-on-kubernetes-b46c3e1af630](https://jmrobles.medium.com/libretranslate-your-own-translation-service-on-kubernetes-b46c3e1af630)
- [https://github.com/LibreTranslate/LibreTranslate](https://github.com/LibreTranslate/LibreTranslate)