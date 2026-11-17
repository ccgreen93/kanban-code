import { test, describe, beforeEach, afterEach } from "node:test";
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { setCardAgent, type AgentFlagDeps } from "./agents/agent-flag.js";
import { setCardAgentOnDisk } from "./cards.js";
import { readLinks } from "./data.js";
import type { SubagentCommandRequest } from "./subagents.js";
import type { Link } from "./types.js";

function card(overrides: Partial<Link> = {}): Link {
  return {
    id: "card_1",
    name: "conductor",
    column: "in_progress",
    createdAt: "2026-11-01T00:00:00Z",
    updatedAt: "2026-11-01T00:00:00Z",
    manualOverrides: {
      worktreePath: false,
      tmuxSession: false,
      name: true,
      column: false,
      prLink: false,
      issueLink: false,
    },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
    ...overrides,
  };
}

describe("setCardAgent", () => {
  test("goes through the app's mailbox while it runs, with what finds a relaunched card", async () => {
    const sent: SubagentCommandRequest[] = [];
    const deps: AgentFlagDeps = {
      appRunning: () => true,
      submit: async (request) => {
        sent.push(request);
        return { id: request.id, ok: true, cardId: "card_app" };
      },
      writeDisk: () => assert.fail("must not write links.json under a running app"),
    };
    const id = await setCardAgent({ cardId: "card_cli", sessionId: "s-1", tmuxName: "conductor" }, true, deps);
    assert.equal(id, "card_app", "answers the card the app changed");
    assert.equal(sent.length, 1);
    assert.equal(sent[0].operation, "setAgent");
    assert.equal(sent[0].cardId, "card_cli");
    assert.equal(sent[0].sessionId, "s-1");
    assert.equal(sent[0].name, "conductor");
    assert.equal(sent[0].isAgent, true);
  });

  test("reports the app's error", async () => {
    const deps: AgentFlagDeps = {
      appRunning: () => true,
      submit: async (request) => ({ id: request.id, ok: false, error: "Card x was not found" }),
      writeDisk: () => false,
    };
    await assert.rejects(setCardAgent({ cardId: "x" }, false, deps), /Card x was not found/);
  });

  test("writes links.json when the app is closed", async () => {
    const written: Array<[string, boolean]> = [];
    const deps: AgentFlagDeps = {
      appRunning: () => false,
      submit: async () => assert.fail("no app to ask"),
      writeDisk: (cardId, isAgent) => {
        written.push([cardId, isAgent]);
        return true;
      },
    };
    assert.equal(await setCardAgent({ cardId: "card_1" }, false, deps), "card_1");
    assert.deepEqual(written, [["card_1", false]]);
  });
});

describe("setCardAgentOnDisk", () => {
  let home: string;
  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "kanban-agent-flag-"));
    process.env.KANBAN_CODE_HOME = home;
  });
  afterEach(() => {
    delete process.env.KANBAN_CODE_HOME;
    rmSync(home, { recursive: true, force: true });
  });

  function seed(link: Link): void {
    writeFileSync(join(home, "links.json"), JSON.stringify({ links: [link] }));
  }

  test("making an agent unpins and unarchives it, like the app's reducer", () => {
    seed(card({ pinnedAt: "2026-11-02T00:00:00Z", pinnedSortOrder: 2, manuallyArchived: true, column: "all_sessions" }));
    setCardAgentOnDisk("card_1", true);
    const [after] = readLinks();
    assert.ok(after.agentAt);
    assert.equal(after.pinnedAt, undefined);
    assert.equal(after.pinnedSortOrder, undefined);
    assert.equal(after.manuallyArchived, false);
    assert.equal(after.column, "backlog");
    assert.notEqual(after.updatedAt, "2026-11-01T00:00:00Z");
  });

  test("moving back to the board clears the flag only", () => {
    seed(card({ agentAt: "2026-11-02T00:00:00Z" }));
    setCardAgentOnDisk("card_1", false);
    const [after] = readLinks();
    assert.equal(after.agentAt, undefined);
    assert.equal(after.column, "in_progress");
  });

  test("an unknown card is reported, not created", () => {
    seed(card());
    assert.equal(setCardAgentOnDisk("card_nope", true), undefined);
    assert.equal(readLinks().length, 1);
  });
});
