// A hand-built stand-in for the slice of `SupabaseClient` that `_shared/db.ts`
// actually touches — plain arrays behind a PostgREST-shaped builder.
//
// Why a fake CLIENT and not stubs for the db.ts helpers: the thing under test in
// notify_test.ts is which call site passes what, so stubbing the functions those
// call sites call would stub away the subject. Sitting one layer lower lets the
// real `devicesFor`, `circleMemberIds` and the two leases run, against rows a
// test can read back afterwards.
//
// Faithful where the handlers depend on it, and no wider:
//   * the builder is a THENABLE, like PostgREST's, so `await query` works and so
//     does `await query.eq(...).maybeSingle()`,
//   * `.update()` hands rows back only when `.select()` asked for them — which
//     is exactly how `claimPostNotification` reads "did I win the lease",
//   * `.is(col, null)` treats an absent key as NULL, because a row literal in a
//     test omits what a table would store as NULL,
//   * `.order()` really sorts. A fake that silently ignores it is a fake that
//     lies, and `devicesFor` orders for a reason (the newest registration wins
//     the 80-row cap).
//
// There is no `auth`. `resolveCallerId` is only ever reached from `handle()`,
// which builds its own client out of the environment and so cannot be driven
// from a test with no --allow-env; the three handlers take their `admin` client
// as a parameter, which is the whole reason they are testable.
//
// Anything db.ts never calls is absent on purpose: an unknown rpc answers with
// an error rather than a shrug, so a test that thinks it is exercising something
// it is not finds out.

import type { Client } from "../../supabase/functions/_shared/db.ts";

export type Row = Record<string, unknown>;

export interface QueryError {
  message: string;
  code?: string;
}

export interface Result<T> {
  data: T;
  error: QueryError | null;
}

/// One query as it was issued. Tests that care about the SHAPE of the traffic
/// read this — "a nudge asks for one person's devices, never the circle's" is a
/// statement about which queries ran, not about their answers.
export interface RecordedQuery {
  table: string;
  op: "select" | "update" | "delete";
  /// PostgREST-ish, e.g. `["user_id=in.(a,b)", "notify_friend_activity=eq.true"]`.
  filters: string[];
}

type Predicate = (row: Row) => boolean;

function clone(row: Row): Row {
  return { ...row };
}

function compare(a: unknown, b: unknown): number {
  if (typeof a === "number" && typeof b === "number") return a - b;
  return String(a).localeCompare(String(b));
}

class FakeQuery implements PromiseLike<Result<Row[] | null>> {
  private readonly predicates: Predicate[] = [];
  private readonly filters: string[] = [];
  private sort: { column: string; ascending: boolean } | null = null;
  private cap: number | null = null;

  constructor(
    private readonly db: FakeSupabase,
    private readonly table: string,
    private readonly op: "select" | "update" | "delete",
    private readonly patch: Row | null,
    private returning: boolean,
  ) {}

  eq(column: string, value: unknown): this {
    this.filters.push(`${column}=eq.${String(value)}`);
    this.predicates.push((row) => row[column] === value);
    return this;
  }

  neq(column: string, value: unknown): this {
    this.filters.push(`${column}=neq.${String(value)}`);
    this.predicates.push((row) => row[column] !== value);
    return this;
  }

  in(column: string, values: readonly unknown[]): this {
    this.filters.push(`${column}=in.(${values.map(String).join(",")})`);
    this.predicates.push((row) => values.includes(row[column]));
    return this;
  }

  /// Only `is(col, null)` is ever issued — both leases use it, and it is the
  /// half of "claim it once" that makes them atomic.
  is(column: string, value: null): this {
    this.filters.push(`${column}=is.${String(value)}`);
    this.predicates.push((row) => (row[column] ?? null) === value);
    return this;
  }

  order(column: string, opts: { ascending?: boolean } = {}): this {
    this.sort = { column, ascending: opts.ascending !== false };
    return this;
  }

  limit(count: number): this {
    this.cap = count;
    return this;
  }

  /// `update(...).select()` — "and hand back what you changed".
  select(_columns?: string): this {
    this.returning = true;
    return this;
  }

  maybeSingle(): Promise<Result<Row | null>> {
    const { data, error } = this.run();
    if (error) return Promise.resolve({ data: null, error });
    const rows = data ?? [];
    if (rows.length > 1) {
      // What PostgREST does, and worth reproducing: `circleIdFor` leans on
      // `unique (user_id)` holding, and a fixture that breaks it should fail
      // loudly rather than quietly pick a row.
      return Promise.resolve({
        data: null,
        error: { message: "multiple rows returned", code: "PGRST116" },
      });
    }
    return Promise.resolve({ data: rows[0] ?? null, error: null });
  }

  then<TResult1 = Result<Row[] | null>, TResult2 = never>(
    onfulfilled?:
      | ((value: Result<Row[] | null>) => TResult1 | PromiseLike<TResult1>)
      | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve(this.run()).then(onfulfilled, onrejected);
  }

  private run(): Result<Row[] | null> {
    this.db.queries.push({
      table: this.table,
      op: this.op,
      filters: [...this.filters],
    });
    const rows = this.db.table(this.table);
    const matched = rows.filter((row) =>
      this.predicates.every((holds) => holds(row))
    );
    switch (this.op) {
      case "select": {
        let out = matched.map(clone);
        if (this.sort) {
          const { column, ascending } = this.sort;
          out.sort((a, b) =>
            compare(a[column], b[column]) * (ascending ? 1 : -1)
          );
        }
        if (this.cap !== null) out = out.slice(0, this.cap);
        return { data: out, error: null };
      }
      case "update": {
        for (const row of matched) Object.assign(row, this.patch ?? {});
        return {
          data: this.returning ? matched.map(clone) : null,
          error: null,
        };
      }
      case "delete": {
        this.db.replace(
          this.table,
          rows.filter((row) => !matched.includes(row)),
        );
        return {
          data: this.returning ? matched.map(clone) : null,
          error: null,
        };
      }
    }
  }
}

export class FakeSupabase {
  /// Every query that has run, in order.
  readonly queries: RecordedQuery[] = [];
  /// Every `rpc()` call, in order — `record_nudge`'s arguments are the sender's
  /// half of the §6 rate limit, so a test may want to read them.
  readonly rpcCalls: { fn: string; args: Row }[] = [];
  /// What each rpc should answer. Nothing is canned by default: a handler that
  /// reaches an rpc the test never described is a handler doing something the
  /// test did not mean to allow.
  readonly rpcResults = new Map<string, Result<unknown>>();

  private readonly tables = new Map<string, Row[]>();

  constructor(seed: Record<string, Row[]> = {}) {
    for (const [table, rows] of Object.entries(seed)) {
      this.tables.set(table, rows.map(clone));
    }
  }

  /// The live rows of a table — read it after a run to check what a lease wrote.
  table(name: string): Row[] {
    const rows = this.tables.get(name);
    if (rows) return rows;
    const empty: Row[] = [];
    this.tables.set(name, empty);
    return empty;
  }

  replace(name: string, rows: Row[]): void {
    this.tables.set(name, rows);
  }

  from(table: string) {
    return {
      select: (_columns?: string) =>
        new FakeQuery(this, table, "select", null, true),
      update: (patch: Row) =>
        new FakeQuery(this, table, "update", patch, false),
      delete: () => new FakeQuery(this, table, "delete", null, false),
    };
  }

  rpc(fn: string, args: Row = {}): Promise<Result<unknown>> {
    this.rpcCalls.push({ fn, args: clone(args) });
    const canned = this.rpcResults.get(fn);
    if (canned) return Promise.resolve(canned);
    return Promise.resolve({
      data: null,
      error: { message: `fake_supabase: no result configured for ${fn}()` },
    });
  }

  /// The one cast, in one place. The handlers are typed against the real
  /// `SupabaseClient`; this fake implements the handful of its methods db.ts
  /// reaches for, and nothing checks the rest at runtime.
  asClient(): Client {
    return this as unknown as Client;
  }
}
