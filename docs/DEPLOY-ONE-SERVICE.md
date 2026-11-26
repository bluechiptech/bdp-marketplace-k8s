# Deploying a change to one service

How to get a code change in one BDP service (or the UI) onto a running
cluster without the full release in [RELEASE.md](RELEASE.md).

The steps are: build the artifact, stage it under `dist/`, build and push one
image to the Azure registry, point the cluster at it, then record the new
digest in the chart.

Use the full release instead when several services changed together or when
you are cutting a version for customers.

## Before you start

- `docker` logged in to `bdpmarketplace.azurecr.io`
  (`az acr login -n bdpmarketplace`, or `docker login bdpmarketplace.azurecr.io`).
- `kubectl` pointed at the target cluster.
- The three repos checked out side by side: `bdp-platform`, `bdp-ui`,
  `bdp-marketplace-k8s`.

The examples use these variables. Run every command from the
`bdp-marketplace-k8s` folder unless it says otherwise.

```bash
SVC=bdp-notification-service        # deployment, container and image share this name
TAG=1.0.7-email.1                   # must be new every time, see "Why a new tag"
ACR=bdpmarketplace.azurecr.io
NS=bdp                              # BDP_NAMESPACE if the install changed it
```

## A platform service (Spring Boot)

1. Build the jar. Run the tests first; `-DskipTests` here only avoids running
   them twice.

   ```bash
   (cd ../bdp-platform && mvn -pl $SVC -am package -DskipTests)
   ```

2. Stage it where the Dockerfile reads it from. `dist/` is git-ignored.

   ```bash
   mkdir -p dist/lib
   cp ../bdp-platform/$SVC/target/$SVC-*-SNAPSHOT.jar dist/lib/$SVC.jar
   ```

3. Build and push the image.

   ```bash
   docker build -f images/Dockerfile.service --build-arg SERVICE=$SVC \
     -t $ACR/bdp/$SVC:$TAG .
   docker push $ACR/bdp/$SVC:$TAG
   ```

   `bdp-provisioner` is the one exception: it uses
   `images/Dockerfile.provisioner` and takes no `SERVICE` build arg.

4. Roll it out and wait.

   ```bash
   kubectl -n $NS set image deploy/$SVC $SVC=$ACR/bdp/$SVC:$TAG
   kubectl -n $NS rollout status deploy/$SVC
   ```

5. Record the digest in the chart (see "Make it permanent").

## The UI

1. Build. Typecheck and lint first.

   ```bash
   (cd ../bdp-ui && npm ci && npm run build)
   ```

2. Stage the standalone output, the same way `collect-artifacts.sh` does.

   ```bash
   rm -rf dist/ui && mkdir -p dist/ui
   cp -r ../bdp-ui/.next/standalone/. dist/ui/
   rm -rf dist/ui/.next/static
   cp -r ../bdp-ui/.next/static dist/ui/.next/static
   cp -r ../bdp-ui/public dist/ui/public
   rm -f dist/ui/.env dist/ui/.env.*
   ```

   The last line matters: the checkout's `.env` holds development addresses
   and secrets, and the chart supplies the real values at runtime.

3. Build, push and roll out.

   ```bash
   docker build -f images/Dockerfile.ui -t $ACR/bdp/bdp-ui:$TAG .
   docker push $ACR/bdp/bdp-ui:$TAG
   kubectl -n $NS set image deploy/bdp-ui bdp-ui=$ACR/bdp/bdp-ui:$TAG
   kubectl -n $NS rollout status deploy/bdp-ui
   ```

## Make it permanent

`kubectl set image` changes only the running cluster. The chart pins every
image by digest, so the next `helm upgrade` puts the old image back unless the
chart is updated.

1. Read the digest of what you pushed.

   ```bash
   docker inspect --format '{{index .RepoDigests 0}}' $ACR/bdp/$SVC:$TAG
   ```

2. In `charts/bdp/values.yaml`, replace the `digest:` under
   `global.azure.images.<service>` with the `sha256:...` part.

3. Check the render, then commit.

   ```bash
   helm template bdp charts/bdp | grep "$SVC@"
   ```

## When the change also touches the chart

If the change adds an environment variable, a secret key or anything else in
`charts/bdp`, `kubectl set image` is not enough: the pod gets the new code but
not the new configuration. Update the digest first, then upgrade the release.

On a cluster installed with `scripts/setup-existing-k8s.sh`, re-run that
script from the updated checkout: it detects the existing release and upgrades
it with the same values it installed with.

Otherwise upgrade by hand:

```bash
helm -n $NS upgrade bdp charts/bdp --reuse-values
```

Either way the upgrade re-runs the seed job. Confirm the admin and engineer
sign-ins still work afterwards; the current passwords are in the
`bdp-credentials` secret.

## Why a new tag

Re-pushing an existing tag and restarting the pod does not deploy anything.
The node already holds an image under that tag and will not pull it again,
and a deployment installed from the chart refers to a digest, which a re-push
does not change. A tag the cluster has never seen forces a pull.

## Checking and undoing

```bash
kubectl -n $NS get deploy/$SVC -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n $NS logs deploy/$SVC --tail=100
kubectl -n $NS rollout undo deploy/$SVC
```

If the pod sits in `ImagePullBackOff`, the cluster cannot read the registry:
check the tag exists (`az acr repository show-tags -n bdpmarketplace
--repository bdp/$SVC`) and that the namespace's pull secret is present.
