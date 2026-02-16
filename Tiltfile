# -*- mode: Python -*-
# Tiltfile for nebari-lgtm-pack local development
#
# No custom images to build — all upstream Grafana images used as-is.
# References:
# - Tilt helm integration: https://docs.tilt.dev/helm.html
# - allow_k8s_contexts: https://docs.tilt.dev/api.html#api.allow_k8s_contexts

# Increase apply timeout for slow operations like image pulls
# Reference: https://docs.tilt.dev/api.html#api.update_settings
update_settings(k8s_upsert_timeout_secs=600)

# Safety: Only allow deployment to local k3d cluster
allow_k8s_contexts('k3d-nebari-dev')

# Deploy the Helm chart
# Reference: https://docs.tilt.dev/helm.html
k8s_yaml(helm(
    '.',
    name='lgtm-pack',
    namespace='default',
    set=[
        # Disable NebariApp CRD for local dev (not running on Nebari)
        'nebariapp.enabled=false',
    ],
))

# Configure Grafana resource for port forwarding
# Reference: https://docs.tilt.dev/api.html#api.k8s_resource
k8s_resource(
    workload='lgtm-pack-grafana',
    port_forwards=['3000:3000'],
    labels=['grafana'],
)

# Label observability backend resources
k8s_resource(
    workload='lgtm-pack-loki',
    labels=['loki'],
)

k8s_resource(
    workload='lgtm-pack-tempo',
    labels=['tempo'],
)

k8s_resource(
    workload='lgtm-pack-mimir-gateway',
    labels=['mimir'],
)

k8s_resource(
    workload='lgtm-pack-mimir-distributor',
    labels=['mimir'],
)

k8s_resource(
    workload='lgtm-pack-mimir-ingester',
    labels=['mimir'],
)

k8s_resource(
    workload='lgtm-pack-mimir-querier',
    labels=['mimir'],
)

k8s_resource(
    workload='lgtm-pack-mimir-query-frontend',
    labels=['mimir'],
)

k8s_resource(
    workload='lgtm-pack-mimir-compactor',
    labels=['mimir'],
)

k8s_resource(
    workload='lgtm-pack-mimir-store-gateway',
    labels=['mimir'],
)
