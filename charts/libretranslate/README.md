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

## HTTPS

`ingress.enabled` exposes the service, and `ingress.kind` decides with what:

| `ingress.kind` | rendered |
| --- | --- |
| `auto` (default) | a Route on OpenShift/OKD, an Ingress on vanilla Kubernetes |
| `ingress` | a `networking.k8s.io/v1` Ingress - also valid on OpenShift, which converts it into a Route |
| `route` | a `route.openshift.io/v1` Route. That API only exists on OpenShift, so off it the chart fails with an explanation instead of rendering a manifest the API server would reject |

Detection is the same one `openshift.enabled` uses, so a plain `helm install`
gets a Route on OpenShift and an Ingress elsewhere with nothing set. `helm
template` has no cluster to inspect, so pass `--set openshift.enabled=true` to
render Routes offline.

### Certificates

`ingress.tls` holds one entry per certificate. Its `hosts` list says which of
the `ingress.hosts` it serves, and an entry without `hosts` serves all of them;
a host with no matching entry stays on plain HTTP. Leave `ingress.tls` empty for
HTTP only.

Reference a secret you created yourself:

```bash
kubectl create secret tls libretranslate-secret-tls --cert=tls.crt --key=tls.key
```

```yaml
ingress:
  enabled: true
  tls:
    - secretName: libretranslate-secret-tls
      hosts:
        - translate.example.com
```

Or hand the certificate and private key to the chart, which creates the secret
for you on Kubernetes and inlines the PEM into the Route on OpenShift:

```bash
helm upgrade --install libretranslate ./chart -f values.yaml \
  --set ingress.enabled=true \
  --set-file ingress.tls[0].certificate=tls.crt \
  --set-file ingress.tls[0].privateKey=tls.key
```

```yaml
ingress:
  tls:
    - secretName: libretranslate-secret-tls   # optional, defaults to <release>-libretranslate-tls
      certificate: |
        -----BEGIN CERTIFICATE-----
        ...
      privateKey: |
        -----BEGIN PRIVATE KEY-----
        ...
      caCertificate: |    # optional
        -----BEGIN CERTIFICATE-----
        ...
```

`certificate` should carry the full chain, leaf certificate first.
`caCertificate` is only needed for a chain the clients would not otherwise
trust. Prefer `--set-file` over putting a private key in a values file you keep
around.

An entry that names only a `secretName` and no inline certificate becomes
`spec.tls.externalCertificate` on a Route, which needs OpenShift 4.16+ with the
`RouteExternalCertificate` feature gate. Inline `certificate`/`privateKey` work
on every version.

### Redirecting HTTP to HTTPS

```yaml
ingress:
  redirectHttpToHttps: true
```

On a Route this is `spec.tls.insecureEdgeTerminationPolicy: Redirect`. Set
`ingress.route.insecureEdgeTerminationPolicy` explicitly to override it - `None`
refuses plain HTTP, `Allow` serves it alongside HTTPS.

An Ingress has no portable field for a redirect, so the chart merges
`ingress.redirectAnnotations` into the ingress annotations instead. They default
to the ingress-nginx pair:

```yaml
ingress:
  redirectAnnotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

Replace them for another controller. Keys you set in `ingress.annotations` win
over them. The redirect needs a `tls` entry - without one there is no HTTPS
endpoint to redirect to, and `helm install` says so in its notes.

### Where TLS is terminated (Routes)

`ingress.route.termination` picks who decrypts:

| | terminated by | pod traffic |
| --- | --- | --- |
| `edge` (default) | the OpenShift router | plain HTTP |
| `reencrypt` | the router, which opens a second TLS connection to the pod | HTTPS |
| `passthrough` | nobody, the pod gets the TLS connection | HTTPS |

`reencrypt` and `passthrough` need LibreTranslate itself to serve TLS, so set
`appSettings.ssl: "true"`. For `reencrypt`, also put the CA that signed the
pod's certificate in `ingress.route.destinationCACertificate`. Routes cannot
match a path when terminating `passthrough`, so `ingress.hosts[].paths` is
ignored there and the whole host is routed to the service.

A Route carries a single host and path, so one Route is rendered per host/path
pair in `ingress.hosts`: the first keeps the release name, the rest get a
numeric suffix (`libretranslate`, `libretranslate-1`, ...).

## OpenShift / OKD

OpenShift's default `restricted-v2` SCC assigns every pod an arbitrary UID and
fsGroup from the namespace's allocated range, and rejects pods that pin their own
IDs or run a container as root.

**This is detected automatically.** `openshift.enabled` is left unset by default,
which makes the chart look for the `security.openshift.io/v1` API and adapt
itself, so a plain `helm install` works on both OpenShift and vanilla
Kubernetes. No SCC of your own is needed - the rendered pod satisfies
`restricted-v2` (and the Pod Security Admission `restricted` profile) as is.

Set the flag explicitly only to force a mode:

```bash
# force OpenShift mode - needed for `helm template`, which has no cluster to
# inspect and therefore falls back to vanilla Kubernetes
helm template libretranslate ./chart --set openshift.enabled=true

# force vanilla mode even on OpenShift, e.g. when your service account is bound
# to the anyuid or nonroot-v2 SCC and you want the pinned UID 1032
helm install libretranslate ./chart --set openshift.enabled=false
```

> **Careful**: if your values file is a full copy of `values.yaml`, delete the
> `openshift.enabled` key from it. Leaving it set to `false` pins it off and the
> pod is rejected with `unable to validate against any security context
> constraint`.

What the two modes render:

| | vanilla Kubernetes | OpenShift |
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
- `XDG_CACHE_HOME` and `XDG_CONFIG_HOME` are pointed at `openshift.cacheDir` and
  `openshift.configDir` (default `/tmp/.cache` and `/tmp/.config`).
  argos-translate derives a data, a config and a cache directory from `~` and
  creates all three on import; the image owns `$HOME` as UID 1032 with mode
  `0755`, so an arbitrary UID cannot create them there. `/tmp` is mode `1777` in
  the image, so any UID can. `XDG_DATA_HOME` is deliberately left unset, so the
  data directory keeps resolving to the mounted models volume.
  Language model archives download into the cache directory, so on `/tmp` they
  consume node ephemeral storage - point `openshift.cacheDir` at a mounted
  volume if that matters for your nodes.
- When `persistence.enabled` is `false`, the model and database directories are
  backed by `emptyDir` volumes rather than the image-owned paths, which the
  arbitrary UID cannot write to. The models are re-downloaded on every pod
  restart, so enable `persistence` for anything but a quick trial.

If your cluster grants the service account the `nonroot-v2` or `anyuid` SCC
instead, set `openshift.enabled=false` to keep the pinned UID 1032 that matches
the image.

## Upgrade

Run the following command to upgrade your LibreTranslate installation. This command will use the Helm chart in the ./chart directory, apply the custom values from values.yaml, and deploy the upgrade to the `libretranslate` namespace:

```bash
helm upgrade --install libretranslate ./chart --namespace libretranslate -f values.yaml
```

> **Tip**: You can use the default [values.yaml](values.yaml)

# References
- [https://jmrobles.medium.com/libretranslate-your-own-translation-service-on-kubernetes-b46c3e1af630](https://jmrobles.medium.com/libretranslate-your-own-translation-service-on-kubernetes-b46c3e1af630)
- [https://github.com/LibreTranslate/LibreTranslate](https://github.com/LibreTranslate/LibreTranslate)