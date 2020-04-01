# DM

Multi-staging Deployment Manager (DM). MD consists of the client and server parts (DMC and DMS  accordingly).

# Installation

1. Install Nix

```bash
curl https://nixos.org/nix/install | sh
```

2. Build the project

```bash
make build
```

# Interact with DMC

```bash
$ result/bin/dmc-exe --help
DMC

Usage: dmc-exe (create | list | edit | destroy | update | info)

Available options:
  -h,--help                Show this help text

Available commands:
  create
  list
  edit
  destroy
  update
  info
```

# Interact with DMS

```bash
$ result/bin/dms-exe --help
DMS

Usage: dms-exe --port INT --db TEXT --db-pool-size INT --tls-cert-path TEXT
               --tls-key-path TEXT --tls-store-path TEXT

Available options:
  -h,--help                Show this help text
```

# Kubernetes installation

1. Deploy DMS's infra

```bash
./b2b-helm-tool -d deploy dms-infra
```

2. Clone b2b-helm to `/tmp`

```bash
git clone https://github.com/Aviora/b2b-helm.git /tmp/b2b-helm
```

3. Give needed permissions for DMS

```bash
cd /tmp/b2b-helm/charts/admin && helm install --name dm-helm-access ./helm-access
cd /tmp/b2b-helm/charts/admin && helm install --name dm-pvc-control ./pvc-control
```

4. Deploy DMS

```bash
./b2b-helm-tool -d deploy dms:dm-v3
```

# How to deploy a new staging

```bash
dmc create --name STAGING_NAME -t DOCKER_IMAGE_TAG -e ENV_VAR1=env_val1 -e ENV_VAR2=env_val2
```

Note that in our ECR(hosted docker registry) we use a convention of
DOCKER_IMAGE_TAG = GIT_SHA. So, if this build was successfully built on github
actions CI and docker image was pushed to ECR, you can deploy it without any
intermediate steps.

# How to override an environment variable in an application

```bash
dmc edit --name STAGING_NAME
```

`dmc edit` opens an `$EDITOR` where you can override staging variables. To
override an environment variable `FOO` with a value `foo`, add a line like this:

```
FOO=foo
```

To commit the changes, save the file and quit your default `$EDITOR`. `:wq` in
vim. Note that to discard your changes, you have to exit your `$EDITOR` with a
not-zero exit code. You can do this by typing `:cq` in vim.
