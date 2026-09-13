# Prepared PostgreSQL test templates

`test_db_template` opts a registered project into provisioning from a dedicated,
operator-prepared template. It supports **one PostgreSQL Ecto repo**, whose existing
test configuration appends `MIX_TEST_PARTITION` (or `test_db_isolation_env`) to its
test database name. Harness does not edit the consuming project or enable this
recipe for existing projects/runs.

```elixir
%Harness.Project{
  # other project fields ...
  test_db_template: %{
    "repo" => "Tapakly.Repo",
    "database" => "tapakly_test",
    "template" => "harness_test_template_tapakly_v1",
    "extensions" => ["vector", "postgis"]
  }
}
```

The recipe is also accepted as the `test_db_template` field in project registry
entries. All four string keys are required; unknown keys fail validation. The
base database must end in `_test`, contain only lowercase ASCII letters, digits
and underscores, and be at most 36 bytes. Template names must start with
`harness_test_template_`. Extension names use the same identifier alphabet.

For this opt-in path, the partition is `_h_` plus 24 hex characters of SHA-256 of
the **entire run id** (96 bits). The base plus partition fits PostgreSQL's 63-byte
identifier limit. Legacy projects keep their existing suffix behavior.

## Operator prerequisites

Use a dedicated test server/role, with PostgreSQL extension binaries already
installed by its administrator. Harness never installs server packages, executes
`CREATE EXTENSION`, grants privileges, or discovers a template from an application
database. Do not copy application data or migration history into a template.

The test role needs `LOGIN`, `CREATEDB`, connection access to the `postgres`
maintenance database, and ownership of its dedicated template. PostgreSQL has no
per-name `CREATEDB` privilege; use a separate test cluster if that scope is too
broad for the application server. Do not grant superuser, role management, or
membership in application roles. Keep `IS_TEMPLATE false`: setting it true would
permit other `CREATEDB` roles to clone the template.

Example **operator** preparation, using an existing `tapakly_test_runner` role:

```sql
-- As the operator on the dedicated test server:
CREATE DATABASE harness_test_template_tapakly_v1
  OWNER tapakly_test_runner TEMPLATE template0;
-- Connect to that new dedicated database as the extension administrator:
CREATE EXTENSION vector;
CREATE EXTENSION postgis;
-- Reconnect to postgres, close all sessions to the template, then:
COMMENT ON DATABASE harness_test_template_tapakly_v1 IS 'harness:test-template:v1';
ALTER DATABASE harness_test_template_tapakly_v1
  WITH ALLOW_CONNECTIONS false IS_TEMPLATE false;
```

The marker is an explicit operator attestation that this is a dedicated test
snapshot. It is not a classifier of arbitrary database contents. Harness checks
only the configured name, owner, marker and frozen flags; it never searches for a
substitute. Extension objects keep their original owners. The test role must have
schema/type/function access needed by the project; project migrations own their
application objects. Templates should contain extensions, not application tables,
data or `schema_migrations`. PostgreSQL does not copy database-level grants or
`ALTER DATABASE ... SET` settings into clones.

## Provisioning, migrations and cleanup

After the worktree/cache is prepared, Harness runs `MIX_ENV=test mix run
--no-start` there, passing the run environment and its partition. Dependencies must
already be available (for example through explicit cache preparation). It loads
Ecto's actual repo configuration, refuses multiple/non-PostgreSQL repos, and
requires the configured database to equal the exact recipe base plus partition.
This catches ignored partition variables, URL overrides and custom repo init
configuration before creating a database. Connection settings come from that
repo; the maintenance database is always `postgres`. Only standard Postgrex
host/socket, port, username/password, TLS and connection-timeout options are
forwarded. Custom connection callbacks, pools and session parameters are not used.

Harness explicitly creates the clone, stamps its run marker, then connects to the
clone to check `pg_extension`. It never connects to the frozen template, so
concurrent runs can clone without validation sessions blocking one another.
A pre-existing partition is an error, never reused. Missing templates/extensions,
wrong owners/markers, connection failures and insufficient privileges fail
preparation with setup evidence; no implementer or reviewer is dispatched.
A database operation has a 30-second deadline and runs in an unlinked Ecto
storage task so a connection failure cannot terminate the provisioning caller.
A clone missing extensions is removed with the same guarded cleanup.

**The independent reviewer owns the project's migrations and checks.** Harness
provisioning is not a check result. The implementer may run the same commands for
development. Existing `ecto.create` steps normally observe an already-created DB;
checks must not drop/recreate it using an unrelated default template. Destructive
reset aliases are incompatible with this contract and must be resolved by the
operator before opting in. Harness does not patch such aliases or provide a
fallback that could make them falsely pass.

On settlement, Harness reloads the worktree's test repo config with the same run
environment. It drops only the exact partition, owned by the connecting role,
with `COMMENT 'harness:test-run:<partition>'` and `IS_TEMPLATE false`. It never
uses unguarded `ecto.drop` for a template-enabled project, never forces a drop,
and never terminates other sessions. Another run, the template and application
DBs are untouched. Missing partitions are harmless. Open connections, changed
repo configuration, removed dependencies or changed markers produce a cleanup
warning with evidence, while preserving the reviewer result.

Cancellation/process death can leave an orphan, including the interval between
`CREATE DATABASE` and its marker. There is no automatic orphan sweep. An operator
must verify the exact run id, partition, server and owner before removing it; an
unmarked DB must not be assumed to belong to Harness. Retained worktrees can be
used to repeat guarded cleanup after resolving connection/configuration failures.

## Invalidation

Version template names when extension versions, server major version, locale,
collation or required extension set changes. Prepare a replacement from
`template0`, validate it, freeze it, then update the registered recipe for future
runs. Do not refresh a template from a live DB, mutate active run databases, or
modify the old template during cloning. Retire old templates only after their
runs have settled. Harness has no time-based template cache or automatic refresh.

## Live test setup

The integration suite requires a **separate disposable PostgreSQL cluster**, with
vector/PostGIS binaries already installed. It never uses the application DB.
Example local setup from the Harness worktree (adjust PostgreSQL binary path):

```sh
mkdir -p .harness/pg/socket
/usr/lib/postgresql/18/bin/initdb -D .harness/pg/data -U postgres --auth=trust --no-locale
/usr/lib/postgresql/18/bin/pg_ctl -D .harness/pg/data -l .harness/pg/server.log \
  -o "-k $PWD/.harness/pg/socket -p 55422 -h ''" start
export HARNESS_TEMPLATE_TEST_SOCKET="$PWD/.harness/pg/socket"
psql -h "$HARNESS_TEMPLATE_TEST_SOCKET" -p 55422 -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c 'CREATE ROLE template_runner LOGIN CREATEDB' \
  -c 'CREATE ROLE template_denied LOGIN' \
  -c 'CREATE DATABASE harness_test_template_probe OWNER template_runner TEMPLATE template0'
psql -h "$HARNESS_TEMPLATE_TEST_SOCKET" -p 55422 -U postgres -d harness_test_template_probe -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION vector' -c 'CREATE EXTENSION postgis'
psql -h "$HARNESS_TEMPLATE_TEST_SOCKET" -p 55422 -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "COMMENT ON DATABASE harness_test_template_probe IS 'harness:test-template:v1'" \
  -c 'ALTER DATABASE harness_test_template_probe ALLOW_CONNECTIONS false'
mix test.json --include integration --no-retry \
  test/harness/run/test_db_template_integration_test.exs \
  test/harness/run/test_db_template_entrypoint_integration_test.exs
/usr/lib/postgresql/18/bin/pg_ctl -D .harness/pg/data stop
```

Missing setup fails the live tests explicitly. Tests run as `template_runner` and
`template_denied`, exercise concurrent clones, extension semantics, real Ecto
migrations/checks, refusal paths and cleanup. Only the operator setup uses the
cluster administrator. The local socket trust configuration is for this disposable
cluster, not an application server.

Contract sources: PostgreSQL [CREATE DATABASE](https://www.postgresql.org/docs/18/sql-createdatabase.html)
(privileges, template locks, ownership and copied settings) and
[Ecto PostgreSQL storage options](https://hexdocs.pm/ecto_sql/Ecto.Adapters.Postgres.html#module-storage-options).
The implementation issues explicit `CREATE DATABASE ... TEMPLATE ...` and uses
Ecto's effective configuration; it does not modify the consumer's `:template` option.
