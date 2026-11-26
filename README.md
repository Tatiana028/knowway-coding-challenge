# Platform Engineering Challenge

A small "agent runs" API behind an nginx reverse proxy, with Postgres as the datastore, all running locally in Docker via Terraform (or OpenTofu).

## Requirements

- Docker (Docker Desktop, or Docker Engine in WSL2)
- Terraform >= 1.5 or OpenTofu >= 1.6
- Python 3.9+ (only for the load generator, no extra packages needed)

## Run

```sh
cd terraform
terraform init   # or: tofu init
terraform apply  # or: tofu apply
```

The proxy listens on http://localhost:8080 , so port 8080 must be free.

```sh
curl localhost:8080/healthz
curl -X POST localhost:8080/runs -H 'Content-Type: application/json' -d '{"agent": "coder"}'
curl localhost:8080/runs
```

## Load generator

```sh
python3 loadgen/loadgen.py --requests 200 --concurrency 4
```

## Logs

```sh
docker logs proxy
docker logs api-1
```

## Tear down

```sh
cd terraform
terraform destroy  # or: tofu destroy
```

If Docker is not reachable at the default socket, set `DOCKER_HOST` (for example `unix://$HOME/.docker/run/docker.sock`).


## Incident notes
### Incident 1: ~50% of requests return 502

**What I saw**

Half of the requests to `/runs` failed with 502. Load generator (200 requests):

    status 200:   20
    status 201:   80
    status 502:  100

**Commands used**

Which upstream caused the 502s:

    grep "status=502" measurements/baseline-proxy.log \
        | awk '{print $5}' | sort | uniq -c
    102 upstream=172.18.0.4:8000

Mapping that IP to a container:

    docker inspect api-2 --format '{{.NetworkSettings.Networks.challenge.IPAddress}}'
    172.18.0.4

So the culprit is api-2. Its logs showed:

    docker logs api-2
    psycopg2.OperationalError: could not translate host name "postgrse"

**Root cause**

Typo in `terraform/main.tf`: `DB_HOST=postgrse` in `api_2` instead of `postgres`. api-2 could not reach the database, so every request routed to it returned 502.

**Fix**

Changed `DB_HOST=postgrse` to `DB_HOST=postgres`. After `tofu apply`, 0% 502 (see Measurements).



### Incident 2: Data disappearing after deploy
**What I saw**

A POSTed record disappeared after redeploying postgres:

    curl -X POST http://localhost:8080/runs \
         -H 'Content-Type: application/json' \
         -d '{"agent": "survivor"}'
    -> {"id": 1, ...}

    tofu apply -replace=docker_container.postgres

    curl http://localhost:8080/runs
    -> []

**Root cause**

The postgres container had no volume. All data was stored inside the container's filesystem. Recreating the container wiped the filesystem and the data with it.

**Fix**

Added a named volume and mounted it at the postgres data directory:

    resource "docker_volume" "postgres_data" {
      name = "postgres_data"
    }

    resource "docker_container" "postgres" {
      ...
      volumes {
        volume_name    = docker_volume.postgres_data.name
        container_path = "/var/lib/postgresql"
      }
    }


## Measurements

I ran the load generator before and after fixing the 502 bug.

**Before the fix:**

    status 200:    20 (10.0%)
    status 201:    80 (40.0%)
    status 502:   100 (50.0%)
    latency p50: 13 ms
    latency p95: 23 ms

**After the fix:**

    status 200:   100 (50.0%)
    status 201:   100 (50.0%)
    latency p50: 13 ms
    latency p95: 32 ms

| Metric         | Before      | After       |
| -------------- | ----------- | ----------- |
| 200/201 success | 100 (50%)   | 200 (100%)   


**All 502s came from a single replica (api-2):**

    grep "status=502" measurements/baseline-proxy.log \
        | awk '{print $5}' | sort | uniq -c
    102 upstream=172.18.0.4:8000   (= api-2)

**Raw data:** `measurements/baseline-loadgen.txt`, `measurements/baseline-proxy.log`, `measurements/baseline-api-2.log` (before); `measurements/after-fix-loadgen.txt`, `measurements/after-fix-proxy.log` (after).

## Hardening

### Network isolation

Before: all containers shared one Docker network. Any container could reach any other, and Postgres was published on the host at `localhost:5432`.

After: the network is split in two.

- `edge` — proxy and both API replicas
- `internal` — both API replicas and Postgres

Postgres is only on `internal`, so the proxy cannot reach it, even if compromised. The proxy stays publicly reachable on `localhost:8080` because that is the intended entry point.

**Verification:**

    # API still works through the proxy (edge):
    curl http://localhost:8080/healthz
    -> {"status": "ok"}

    # Postgres is no longer reachable from the host:
    nc -zv localhost 5432
    -> Connection refused

    # api-2 still reaches Postgres (internal):
    docker logs api-2 --tail 3
    -> listening on :8000, db host postgres   (no errors)

### Terraform variables

Moved configuration into `terraform/variables.tf`:

- `postgres_image`  
- `db_password`  
- `db_name`  
- `proxy_external_port`  

For this challenge I kept defaults in `variables.tf` so the stack runs out of the box. For a real deployment I would move secrets out of code  

### Output

`main.tf` exposes the proxy URL as a Terraform output. It now uses the variable:

    output "proxy_url" {
      value = "http://localhost:${var.proxy_external_port}"
    }

    # tofu apply ends with:
    #   proxy_url = "http://localhost:8080"


## AI usage

I used Claude as a pair-programming assistant throughout this challenge.

**Where it helped:**
- Explained concepts I was not familiar with (Docker volumes, Terraform resource references, network isolation).
- Helped build the shell commands I used to verify each fix.
- Drafted this report, which I then edited.

**Where it was wrong:**
- Suggested `tofu destroy && tofu apply` to test the data-loss fix. But `destroy` also deletes the volume, so of course the data was gone , the test did not actually prove anything. The right command was `tofu apply -replace=docker_container.postgres`: it only recreates the container and leaves the volume in place.

**How I verified:**
- Every command in this README was actually run and the output observed.
- Every claim is backed by a file in `measurements/`.
- Where the assistant explained concepts, I asked follow-ups until I could restate the reasoning in my own words.