# Infrastructure

The app is already built. Services to deploy:

- **web** — the application container. Listens on port 80, health check at `GET /up`.
- **db** — PostgreSQL accessory (`supabase/postgres`) for application data.
