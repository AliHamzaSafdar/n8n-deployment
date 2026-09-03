# n8n on EC2

Postgres + n8n + Caddy (automatic TLS). One host, one compose file.

## Before the box

1. **EC2** — Ubuntu 24.04, `t3.small` or larger (`t3.micro` OOMs once a few
   workflows run concurrently), 20 GB gp3.
2. **Elastic IP** — allocate, associate with the instance. Without it a
   stop/start changes the public IP and breaks DNS plus every webhook URL.
3. **Security group** — inbound only:

   | Port | Source |
   |------|--------|
   | 22   | your IP / VPN only |
   | 80   | 0.0.0.0/0 (Let's Encrypt HTTP-01 challenge) |
   | 443  | 0.0.0.0/0 |

   Port 5678 stays closed. The compose file never publishes it.
4. **DNS** — A record for your subdomain to the Elastic IP. Do this *before*
   starting the stack; Caddy's cert request fails if the name does not resolve.

## On the box

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER
# log out and back in for the group to take effect
```

Copy this directory to `~/n8n`, then:

```bash
cd ~/n8n
cp .env.example .env
openssl rand -hex 24   # -> POSTGRES_PASSWORD
openssl rand -hex 32   # -> N8N_ENCRYPTION_KEY
nano .env              # set DOMAIN, ACME_EMAIL, both secrets
mkdir -p files
docker compose up -d
docker compose logs -f caddy      # watch the certificate get issued
```

Open `https://<your domain>` and **create the owner account immediately**. Until
you do, the instance is claimable by anyone who reaches it.

## Operating it

```bash
docker compose logs -f n8n        # tail logs
docker compose pull && docker compose up -d   # upgrade n8n
docker compose down               # stop (volumes survive)
```

### Backups

Everything you build lives in Postgres. Back it up on a schedule:

```bash
docker compose exec -T postgres pg_dump -U n8n n8n | gzip > n8n-$(date +%F).sql.gz
```

Store `N8N_ENCRYPTION_KEY` alongside the dump, off the instance. A database
backup without that key restores your workflows but none of your credentials.

Also export workflow JSON so the instance is not the only source of truth:

```bash
docker compose exec n8n n8n export:workflow --all --separate --output=/files/workflows
```

`/files` is bind-mounted to `./files` on the host, so the exports land next to
this README and can be committed to git.

## Gotchas

- **Docker bypasses UFW.** Docker writes its own iptables rules. The security
  group is your real firewall here; do not assume UFW is protecting anything.
- **`WEBHOOK_URL` must match the public origin.** It is already wired to
  `DOMAIN` in the compose file. If webhook URLs still show `localhost`, the
  variable did not reach the container -- check `.env`.
- **Manual runs never fire the Error Workflow.** Only scheduled, webhook, and
  sub-workflow executions do.
- **Credentials do not travel in exported workflow JSON**, by design. After
  importing on a new instance you re-select credentials per node.
- **`EXECUTIONS_TIMEOUT: -1`** means an execution can run forever. That is
  deliberate for long shell jobs; set a seconds value if you want a ceiling.
