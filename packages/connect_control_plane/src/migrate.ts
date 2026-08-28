import { loadDatabaseUrl } from "./config.ts";
import { runMigrations } from "./migrations.ts";

await runMigrations(loadDatabaseUrl());
console.log("Verde Connect migrations are current");
