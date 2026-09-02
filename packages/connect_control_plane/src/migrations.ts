import { readdir } from "node:fs/promises";

import postgres from "postgres";

export async function runMigrations(databaseUrl: string): Promise<void> {
  const sql = postgres(databaseUrl, {
    max: 1,
    connect_timeout: 5,
    idle_timeout: 5,
    onnotice: () => undefined,
  });
  try {
    await sql.begin(async (transaction) => {
      await transaction`SELECT pg_advisory_xact_lock(1447382601)`;
      await transaction`
        CREATE TABLE IF NOT EXISTS connect_schema_migrations (
          version text PRIMARY KEY,
          applied_at timestamptz NOT NULL DEFAULT now()
        )
      `;
      const directory = new URL("../migrations/", import.meta.url);
      const files = (await readdir(directory))
        .filter((name) => /^\d+_[a-z0-9_]+\.sql$/.test(name))
        .sort();
      for (const fileName of files) {
        const existing = await transaction<{ present: boolean }[]>`
          SELECT EXISTS (
            SELECT 1 FROM connect_schema_migrations WHERE version = ${fileName}
          ) AS present
        `;
        if (existing[0]?.present === true) continue;
        const source = await Bun.file(new URL(fileName, directory)).text();
        await transaction.unsafe(source);
        await transaction`
          INSERT INTO connect_schema_migrations (version) VALUES (${fileName})
        `;
      }
    });
  } finally {
    await sql.end({ timeout: 5 });
  }
}
