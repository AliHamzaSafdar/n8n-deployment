# n8n on EC2

Postgres + n8n + Caddy (automatic TLS). One host, one compose file.

Sized for a 2 GB instance (`t4g.small` / `t3.small`). The container memory
limits in `docker-compose.yml` add up to ~1.6 GB and are chosen together --
raising one alone just lets it starve the other two.

## Before the box

1. **EC2** — Ubuntu 24.04, `t3.small` or `t4g.small`, 20 GB gp3. The `.micro`
   sizes of either OOM once a few workflows run concurrently.

   Match the AMI architecture to the family: **x86_64** for `t3`, **arm64**
   for `t4g` (Graviton). All three images are multi-arch, so the stack runs
   either way. The difference is the ecosystem — on arm64, community nodes
   shipping native binaries and anything Chromium/Puppeteer-based may not
   install. On `t3` that is a non-issue.

2. **Burstable CPU credits** — `t4g`/`t3` default to *unlimited* mode, which
   silently bills a surcharge for sustained CPU above the 20% baseline instead
   of throttling. Switch to standard mode if you would rather be slow than
   surprised:

   ```bash
   aws ec2 modify-instance-credit-specification \
     --instance-credit-specification "InstanceId=<id>,CpuCredits=standard"
   ```

3. **Elastic IP** — allocate, associate with the instance. Without it a
   stop/start changes the public IP and breaks DNS plus every webhook URL.

4. **Security group** — inbound only:

   | Port      | Source                                    |
   |-----------|-------------------------------------------|
   | 22 TCP    | your IP / VPN only                        |
   | 80 TCP    | 0.0.0.0/0 (Let's Encrypt HTTP-01 challenge) |
   | 443 TCP   | 0.0.0.0/0                                 |
   | 443 UDP   | 0.0.0.0/0 (HTTP/3 — or drop the `443:443/udp` line from the compose file) |

   Port 5678 stays closed. The compose file never publishes it.

5. **DNS** — A record for your subdomain to the Elastic IP. Do this *before*
   starting the stack; Caddy's cert request fails if the name does not resolve.

## On the box

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER
# log out and back in for the group to take effect
```

Confirm swap exists — 2 GB of RAM without it means the kernel OOM-kills a
container instead of paging:

```bash
swapon --show    # want a 2 GB file; if empty, see "Adding swap" below
```

Copy this directory to `~/n8n`, then:

```bash
cd ~/n8n
cp .env.example .env
openssl rand -hex 24   # -> POSTGRES_PASSWORD
openssl rand -hex 32   # -> N8N_ENCRYPTION_KEY
nano .env              # set DOMAIN, ACME_EMAIL, N8N_VERSION, both secrets
chmod 600 .env
mkdir -p files
docker compose up -d
docker compose logs -f caddy      # watch the certificate get issued
```

`N8N_VERSION` has no default on purpose. Pick a tag from
[the releases page](https://github.com/n8n-io/n8n/releases) — with `latest`, a
routine `docker compose pull` is an unannounced major upgrade.

Open `https://<your domain>` and **create the owner account immediately**. Until
you do, the instance is claimable by anyone who reaches it.

### Adding swap

Only if `swapon --show` came back empty:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## Operating it

```bash
docker compose logs -f n8n        # tail logs
docker compose ps                 # health column, not just "Up"
docker stats --no-stream          # how close each container is to its limit
docker compose down               # stop (volumes survive)
```

Upgrading is a deliberate act: bump `N8N_VERSION` in `.env`, back up first,
then

```bash
./backup.sh
docker compose pull && docker compose up -d
```

### Backups

Everything you build lives in Postgres. `backup.sh` dumps it, exports workflow
JSON, verifies the gzip, and prunes dumps older than `KEEP_DAYS`. It sources
`.env` itself, because cron runs with almost no environment:

```bash
chmod +x backup.sh
crontab -e
# 15 3 * * * /home/ubuntu/n8n/backup.sh >> /home/ubuntu/n8n/backup.log 2>&1
```

Set `BACKUP_S3` in `.env` (and give the instance an IAM role that can write
there). A dump sitting on the same EBS volume as the database dies with it.

Store `N8N_ENCRYPTION_KEY` alongside the dumps, off the instance. A database
backup without that key restores your workflows but none of your credentials.

Test a restore before you need one:

```bash
gunzip -c backups/n8n-<stamp>.sql.gz | docker compose exec -T postgres psql -U n8n -d n8n
```

## Gotchas

- **Docker bypasses UFW.** Docker writes its own iptables rules. The security
  group is your real firewall here; do not assume UFW is protecting anything.
- **Anyone with editor access can run code.** Code and Execute Command nodes
  run inside the n8n container. `N8N_RESTRICT_FILE_ACCESS_TO=/files` and
  `N8N_BLOCK_ENV_ACCESS_IN_NODE=true` keep that away from the container's
  environment, which holds the encryption key and the database password. Drop
  the env block only if a workflow genuinely needs `$env`.
- **`WEBHOOK_URL` must match the public origin.** It is already wired to
  `DOMAIN` in the compose file. If webhook URLs still show `localhost`, the
  variable did not reach the container -- check `.env`.
- **Executions time out at one hour** (`EXECUTIONS_TIMEOUT`), and at most five
  run in parallel (`N8N_CONCURRENCY_PRODUCTION_LIMIT`). Both are RAM ceilings,
  not preferences -- raise them only alongside `mem_limit` and `NODE_OPTIONS`.
- **Manual runs never fire the Error Workflow.** Only scheduled, webhook, and
  sub-workflow executions do.
- **Changing `N8N_ENCRYPTION_KEY` after first boot is not a one-line edit.**
  n8n stamps the key into `/home/node/.n8n/config` inside the `n8n_data`
  volume on first run, and refuses to start when the two disagree:
  `Mismatching encryption keys`. To change it, update the settings file too:

  ```bash
  docker compose stop n8n
  docker compose run --rm -T --entrypoint sh n8n -c \
    'printf "{\"encryptionKey\":\"%s\"}" "$N8N_ENCRYPTION_KEY" > /home/node/.n8n/config'
  docker compose up -d n8n
  ```

  Only safe while nothing is encrypted under the old key -- otherwise every
  existing credential becomes unreadable.
- **`docker compose run` steals stdin.** It will silently eat the rest of a
  heredoc-driven remote script. Add `</dev/null` to every such call.
- **Importing workflows deactivates them.** `n8n import:workflow` logs
  `Deactivating workflow "..."` for anything that was active in the export.
  Re-enable them by hand after a migration.
- **A Postgres major upgrade needs a dump and restore.** The data directory is
  version-specific, so bumping the image tag alone leaves the container unable
  to start. Dump, point the service at a fresh volume, restore, and keep the
  old volume until the new one has proven itself.
- **Credentials do not travel in exported workflow JSON**, by design. After
  importing on a new instance you re-select credentials per node.
