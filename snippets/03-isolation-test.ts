// A cross-tenant isolation test that lives in the normal test suite
// (illustrative, written for this case study).
//
// It signs in as users of two firms plus an anonymous visitor, looks at
// every table and view, and fails if anyone can reach another office's rows.
// Uses the open-source pg-tenant-probe: https://github.com/mazendrop/pg-tenant-probe
import pg from "pg";
import { describe, expect, it } from "vitest";
import { formatText, probe } from "pg-tenant-probe";

const FIRM_A = "6f1c0e52-0000-4000-8000-00000000000a";
const FIRM_B = "6f1c0e52-0000-4000-8000-00000000000b";

describe("tenant isolation", () => {
  it("no principal can read or write another office's rows", async () => {
    // A seeded test database, never production: write probes are rolled back, but triggers still fire.
    const client = new pg.Client(process.env.TEST_DATABASE_URL);
    await client.connect();
    try {
      const report = await probe(client, {
        preset: "supabase",
        tenantColumn: "firm_id",
        tables: {
          firms: { tenant: "id" },
          // child rows inherit the office of their parent
          matter_events: { tenant: "(select c.firm_id from matters c where c.id = r.matter_id)" },
          court_directory: { shared: true },
        },
        writes: true,
        principals: [
          { name: "lawyer in A", tenant: FIRM_A, claims: { sub: "1b9d6bcd-0000-4000-8000-0000000000a1" } },
          { name: "trainee in A", tenant: FIRM_A, claims: { sub: "1b9d6bcd-0000-4000-8000-0000000000a2" } },
          { name: "owner of B", tenant: FIRM_B, claims: { sub: "1b9d6bcd-0000-4000-8000-0000000000b1" } },
          { name: "anonymous" },
        ],
      });

      if (!report.summary.ok) console.log(formatText(report));
      expect(report.summary.leaks).toBe(0);
      expect(report.summary.ok).toBe(true);
      // "0 leaks" must mean something: other tenants had rows to leak.
      expect(report.checks.filter((c) => c.kind === "read" && c.status === "pass").length).toBeGreaterThan(0);
    } finally {
      await client.end();
    }
  });
});
